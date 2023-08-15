locals {
  max_subnet_length = max(
    length(var.private_subnet_cidrs),
    length(var.public_subnet_cidrs),
    length(var.database_subnet_cidrs),
  )

  len_private_subnets  = max(length(var.private_subnet_cidrs))
  len_public_subnets   = max(length(var.public_subnet_cidrs))
  len_database_subnets = max(length(var.database_subnet_cidrs))

  nat_gateway_count = var.single_nat_gateway ? 1 : var.one_nat_gateway_per_az ? length(var.azs) : local.max_subnet_length
  
  # Use `local.vpc_id` to give a hint to Terraform that subnets should be deleted before secondary CIDR blocks can be free!
  vpc_id = try(aws_vpc_ipv4_cidr_block_association.main[0].vpc_id, aws_vpc.main_vpc[0].id, "")
  
  create_vpc = var.create_vpc
}

# ========  VPC  ========
resource "aws_vpc" "main_vpc" {
  count = local.create_vpc ? 1 : 0

  cidr_block            = var.vpc_cidr
  instance_tenancy      = var.instance_tenancy
  enable_dns_hostnames  = var.enable_dns_hostnames
  enable_dns_support    = var.enable_dns_support
    
  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.vpc_tags,
  )
}

resource "aws_vpc_ipv4_cidr_block_association" "main" {
  count = local.create_vpc && length(var.secondary_cidr_blocks) > 0 ? length(var.secondary_cidr_blocks) : 0

  # Do not turn this into `local.vpc_id`
  vpc_id = aws_vpc.main_vpc[0].id

  cidr_block = element(var.secondary_cidr_blocks, count.index)
}


# ========  Internet GW  ========
resource "aws_internet_gateway" "vpc_gw" {
  count = local.create_vpc && var.create_igw && length(var.public_subnet_cidrs) > 0 ? 1 : 0
  
  # vpc_id = aws_vpc.main_vpc.id
  vpc_id = local.vpc_id
  
  tags = merge(
    { "Name" = var.name },
    var.tags,
    var.igw_tags,
  )
}


# ========  Route Table for Public Subnets  ========
resource "aws_route_table" "public_subnets" {
  count = local.create_vpc && length(var.public_subnet_cidrs) > 0 ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(
    { "Name" = "${var.name}-${var.public_subnet_suffix}" },
    var.tags,
    var.public_route_table_tags,
  )
}

# ========  Route Table for Private Subnets  ========
resource "aws_route_table" "private" {
  count = local.create_vpc && local.max_subnet_length > 0 ? local.nat_gateway_count : 0
  
  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.single_nat_gateway ? "${var.name}-${var.private_subnet_suffix}" : format(
        "${var.name}-${var.private_subnet_suffix}-%s",
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.private_route_table_tags,
  )
}


resource "aws_route" "public_internet_gateway" {
  count = local.create_vpc && var.create_igw && length(var.public_subnet_cidrs) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public_subnets[0].id
  destination_cidr_block = var.default_cidr
  gateway_id             = aws_internet_gateway.vpc_gw[0].id
}

# ========  Public Subnets  ========
locals {
  create_public_subnets = local.create_vpc && local.len_public_subnets > 0
}

resource "aws_subnet" "public_subnets" {
  count = local.create_vpc && length(var.public_subnet_cidrs) > 0 && (false == var.one_nat_gateway_per_az || length(var.public_subnet_cidrs) >= length(var.azs)) ? length(var.public_subnet_cidrs) : 0

  vpc_id                  = local.vpc_id
  cidr_block              = element(concat(var.public_subnet_cidrs, [""]), count.index)
  availability_zone       = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id    = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(
    {
      Name = try(
        var.public_subnet_names[count.index],
        format("${var.name}-${var.public_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    var.tags,
    var.public_subnet_tags,
    lookup(var.public_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}
# ========= Public - NACL =========

resource "aws_network_acl" "public" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? 1 : 0

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.public_subnets[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.public_subnet_suffix}" },
    var.tags,
    var.public_acl_tags,
  )
}

resource "aws_network_acl_rule" "public_inbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id

  egress          = false
  rule_number     = var.public_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_inbound_acl_rules[count.index], "cidr_block", null)
}

resource "aws_network_acl_rule" "public_outbound" {
  count = local.create_public_subnets && var.public_dedicated_network_acl ? length(var.public_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.public[0].id

  egress          = true
  rule_number     = var.public_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.public_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.public_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.public_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.public_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.public_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.public_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.public_outbound_acl_rules[count.index], "cidr_block", null)
}


# ========  Private Subnets  ========
locals {
  create_private_subnets = local.create_vpc && local.len_private_subnets > 0
}

resource "aws_subnet" "private_subnets" {
  count = local.create_vpc && length(var.public_subnet_cidrs) > 0 ? length(var.public_subnet_cidrs) : 0

  vpc_id               = local.vpc_id
  cidr_block           = element(var.private_subnet_cidrs, count.index)
  availability_zone    = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
 
  tags = merge(
    {
      Name = try(
        var.private_subnet_names[count.index],
        format("${var.name}-${var.private_subnet_suffix}-%s", element(var.azs, count.index))
      )
    },
    var.tags,
    var.private_subnet_tags,
    lookup(var.private_subnet_tags_per_az, element(var.azs, count.index), {})
  )
}

# ========= Private - NACL =========

locals {
  create_private_network_acl = local.create_private_subnets && var.private_dedicated_network_acl
}

resource "aws_network_acl" "private" {
  count = local.create_private_network_acl ? 1 : 0

  vpc_id     = local.vpc_id
  subnet_ids = aws_subnet.private_subnets[*].id

  tags = merge(
    { "Name" = "${var.name}-${var.private_subnet_suffix}" },
    var.tags,
    var.private_acl_tags,
  )
}

resource "aws_network_acl_rule" "private_inbound" {
  count = local.create_private_network_acl ? length(var.private_inbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id

  egress          = false
  rule_number     = var.private_inbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_inbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_inbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_inbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_inbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_inbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_inbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_inbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_inbound_acl_rules[count.index], "ipv6_cidr_block", null)
}

resource "aws_network_acl_rule" "private_outbound" {
  count = local.create_private_network_acl ? length(var.private_outbound_acl_rules) : 0

  network_acl_id = aws_network_acl.private[0].id

  egress          = true
  rule_number     = var.private_outbound_acl_rules[count.index]["rule_number"]
  rule_action     = var.private_outbound_acl_rules[count.index]["rule_action"]
  from_port       = lookup(var.private_outbound_acl_rules[count.index], "from_port", null)
  to_port         = lookup(var.private_outbound_acl_rules[count.index], "to_port", null)
  icmp_code       = lookup(var.private_outbound_acl_rules[count.index], "icmp_code", null)
  icmp_type       = lookup(var.private_outbound_acl_rules[count.index], "icmp_type", null)
  protocol        = var.private_outbound_acl_rules[count.index]["protocol"]
  cidr_block      = lookup(var.private_outbound_acl_rules[count.index], "cidr_block", null)
  ipv6_cidr_block = lookup(var.private_outbound_acl_rules[count.index], "ipv6_cidr_block", null)
}


# ========  Database Subnets  ========
resource "aws_subnet" "database" {
  count = local.create_database_subnets ? local.len_database_subnets : 0

  vpc_id               = local.vpc_id
  cidr_block           = element(concat(var.database_subnet_cidrs, [""]), count.index)
  availability_zone    = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null  


  tags = merge(
    {
      Name = try(
        var.database_subnet_names[count.index],
        format("${var.name}-${var.database_subnet_suffix}-%s", element(var.azs, count.index), )
      )
    },
    var.tags,
    var.database_subnet_tags,
  )
}

resource "aws_route_table" "database" {
  count = local.create_vpc && local.max_subnet_length > 0 ? local.nat_gateway_count : 0
  
  vpc_id = local.vpc_id

  tags = merge(
    {
      "Name" = var.single_nat_gateway ? "${var.name}-${var.database_subnet_suffix}" : format(
        "${var.name}-${var.database_subnet_suffix}-%s",
        element(var.azs, count.index),
      )
    },
    var.tags,
    var.database_route_table_tags,
  )
}

resource "aws_route" "database_nat_gateway" {
  count = local.create_vpc && var.enable_nat_gateway ? local.nat_gateway_count : 0

  route_table_id         = element(aws_route_table.private[*].id, count.index)
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = element(aws_nat_gateway.main[*].id, count.index)  
}

resource "aws_route_table_association" "database" {
  count = local.create_vpc && length(var.public_subnet_cidrs) > 0 ? length(var.public_subnet_cidrs) : 0

  subnet_id      = element(aws_subnet.database[*].id, count.index) 
  route_table_id = element(aws_route_table.database[*].id, var.single_nat_gateway ? 0 : count.index)
}


# ========  NAT Gateway  ========
locals {
  nat_gateway_ips = var.reuse_nat_ips ? var.external_nat_ip_ids : try(aws_eip.nat[*].id, [])
}

resource "aws_eip" "nat" {
  count = local.create_vpc && var.enable_nat_gateway && false == var.reuse_nat_ips ? local.nat_gateway_count : 0

  domain = "vpc"

  tags = merge(
    {
      "Name" = format(
        "${var.name}-%s",
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    var.tags,
    var.nat_eip_tags,
  )
}


resource "aws_nat_gateway" "main" {
  count = local.create_vpc && var.enable_nat_gateway ? local.nat_gateway_count : 0

  allocation_id = element(local.nat_gateway_ips, var.single_nat_gateway ? 0 : count.index)
  subnet_id     = element(aws_subnet.public_subnets[*].id, var.single_nat_gateway ? 0 : count.index)

  depends_on = [aws_internet_gateway.vpc_gw]

  tags = merge(
    {
      "Name" = format(
        "${var.name}-%s",
        element(var.azs, var.single_nat_gateway ? 0 : count.index),
      )
    },
    var.tags,
    var.nat_gateway_tags,
  )
}


resource "aws_route" "private_nat_gateway" {
  count = local.create_vpc && var.enable_nat_gateway ? local.nat_gateway_count : 0

  route_table_id         = element(aws_route_table.private[*].id, count.index)
  destination_cidr_block = var.nat_gateway_destination_cidr_block
  nat_gateway_id         = element(aws_nat_gateway.main[*].id, count.index)  
}

resource "aws_route_table_association" "private" {
  count = local.create_vpc && length(var.public_subnet_cidrs) > 0 ? length(var.public_subnet_cidrs) : 0

  subnet_id      = element(aws_subnet.private_subnets[*].id, count.index) 
  route_table_id = element(aws_route_table.private[*].id, var.single_nat_gateway ? 0 : count.index)
}









resource "aws_route_table_association" "public" {
  count = local.create_vpc && length(var.public_subnet_cidrs) > 0 ? length(var.public_subnet_cidrs) : 0

  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.public_subnets[0].id
}