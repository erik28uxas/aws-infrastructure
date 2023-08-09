locals {
  max_subnet_length = max(
    length(var.private_subnet_cidrs),
    # length(var.database_subnets),
  )
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

# ========  Private Subnets  ========
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