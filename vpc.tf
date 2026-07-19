# Asks AWS which AZs exist in this region at runtime.
# Better than hardcoding "ap-south-1a" etc - AZ names can vary per account.
data "aws_availability_zones" "available" {
  state = "available"
}

# Main network - 10.0.0.0/16 gives us 65k IPs to slice into subnets.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
    # DNS support + hostnames both required by EKS, cluster creation fails without them.
  tags = {
    Name = "${local.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project_name}-igw"
  }
}

# Two public subnets, one per AZ (EKS control plane needs min 2 AZs).
# count=2 runs this block twice: index 0 -> 10.0.0.0/24 in first AZ,
# index 1 -> 10.0.1.0/24 in second AZ.
# Public subnets only, no NAT gateway as it costs more - in a real prod setup nodes would sit in private
# subnets behind NAT.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true 

  tags = {
    Name = "${local.project_name}-public-${count.index}"
    # EKS + LB controller find subnets through these tags.
    # Missing them = LoadBalancer services fail to create, silently.
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.project_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}