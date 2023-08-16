terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

terraform {
  backend "s3" {
    bucket = "eg-aws-infrastructure-remote-state-tf"
    key = "env/network/vpc-main"
    region = "us-west-2"
  }
}

provider "aws" {
    region = local.region
}

locals {
  region = "us-west-2"

  tags = {
    ManagedBy = "Terraform"
    Owner     = "Ernest"
  }
}


module "vpc" {
  source = "/home/erikgoul/Documents/Terraform_infra/aws-infrastructure/modules/network/vpc-main"


  vpc_cidr = "10.0.0.0/16"

  azs                   = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnet_cidrs  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  database_subnet_cidrs = ["10.0.7.0/24", "10.0.8.0/24"]


  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true 
  # external_nat_ip_ids    = "${aws_eip.nat.*.id}"

  # public_subnet_names = "Main Public Subnet"
  
  
  name = "Main"

  public_subnet_tags = {
    Name = "Main VPC public subnet" 
  }

  public_subnet_tags_per_az = {
    "${local.region}a" = {
      "availability-zone" = "${local.region}a"
    }
    "${local.region}b" = {
      "availability-zone" = "${local.region}b"
    }
    "${local.region}c" = {
      "availability-zone" = "${local.region}c"
    }
  }

  private_subnet_tags = {
    Name = "Main VPC private subnet" 
  }

  private_subnet_tags_per_az = {
    "${local.region}a" = {
      "availability-zone" = "${local.region}a"
    }
    "${local.region}b" = {
      "availability-zone" = "${local.region}b"
    }
    "${local.region}c" = {
      "availability-zone" = "${local.region}c"
    }
  }


  vpc_tags = {
    Name = "Main VPC"
  }

  igw_tags = {
    Name = "Main VPC IGW"
  }


  tags = local.tags
}