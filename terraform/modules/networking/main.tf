# =============================================================================
# terraform/modules/networking/main.tf
# =============================================================================

# -----------------------------------------------------------------------------
# RESOURCE 1: The VPC itself
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # DNS support lets resources inside the VPC resolve AWS service DNS names
  # (like an RDS endpoint or an S3 VPC endpoint) to internal IPs. Without
  # this, some AWS-managed services simply won't work correctly.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 2: Internet Gateway
# -----------------------------------------------------------------------------
# WHY THIS EXISTS: A VPC is, by default, a fully isolated private network —
# nothing inside it can reach the internet, and nothing outside can reach
# in. An Internet Gateway is the literal "door" AWS attaches to a VPC to
# make internet connectivity possible at all. It's a single resource, and
# only public subnets will route traffic through it (private subnets never
# will — that's the whole point of the public/private split).
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}


# -----------------------------------------------------------------------------
# RESOURCE 3: Public subnets — one per Availability Zone
# -----------------------------------------------------------------------------
# WHY `count` HERE: We have a LIST of AZs and a LIST of CIDRs, and we want
# one subnet per pair. `count.index` lets us walk through both lists in
# lockstep — count.index 0 uses availability_zones[0] + public_subnet_cidrs[0],
# count.index 1 uses the second entry of each, and so on. This is exactly
# how you avoid copy-pasting a near-identical resource block per AZ.
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # This means any EC2 instance (or load balancer ENI) launched directly
  # into this subnet automatically gets a public IP — required for a
  # public-facing Application Load Balancer to actually be reachable.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${var.availability_zones[count.index]}"

    # ---------------------------------------------------------------------
    # THESE TWO TAGS ARE NOT DECORATION — EKS reads them at runtime.
    # ---------------------------------------------------------------------
    # "kubernetes.io/cluster/<name> = shared" tells EKS "this subnet
    # belongs to this cluster and can be shared with other AWS resources
    # (like a load balancer)." Without this exact tag, the AWS Load
    # Balancer Controller (which we'll install later) literally cannot
    # discover which subnets it's allowed to place an ALB into — it
    # doesn't guess, it reads this tag.
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"

    # This second tag specifically marks the subnet as suitable for an
    # INTERNET-FACING load balancer (elb = external load balancer).
    # ---------------------------------------------------------------------
    "kubernetes.io/role/elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 4: Private subnets — one per Availability Zone
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Deliberately NO map_public_ip_on_launch here — anything launched into
  # this subnet gets no public IP at all, by default. This is the actual
  # mechanism that makes a subnet "private" — it's not a label, it's this.

  tags = {
    Name = "${var.cluster_name}-private-${var.availability_zones[count.index]}"

    "kubernetes.io/cluster/${var.cluster_name}" = "shared"

    # "internal-elb" marks this subnet as suitable for an INTERNAL load
    # balancer only — one that's reachable inside the VPC but never from
    # the public internet. We may use this later for internal services.
    "kubernetes.io/role/internal-elb" = "1"
  }
}


# -----------------------------------------------------------------------------
# RESOURCE 5: Elastic IP for the NAT Gateway
# -----------------------------------------------------------------------------
# WHY THIS EXISTS SEPARATELY: A NAT Gateway needs a fixed, public IP address
# to present to the internet — that's what an Elastic IP is: a static
# public IPv4 address you can attach to AWS resources. We allocate it as
# its own resource because NAT Gateway and Elastic IP are genuinely
# separate AWS objects with separate lifecycles.
#
# `count` here uses a CONDITIONAL: if single_nat_gateway is true, create
# exactly 1. Otherwise, create one per AZ. This is the actual mechanism
# behind the cost-vs-redundancy trade-off we just discussed.
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : length(var.availability_zones)
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip-${count.index}"
  }

  # An EIP must be created only after the Internet Gateway exists — EIPs
  # intended for VPC use depend on the VPC already having internet
  # connectivity established. Terraform usually infers this automatically
  # from references, but NAT-related resources are a known case where
  # being explicit avoids a rare race condition during creation.
  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# RESOURCE 6: The NAT Gateway itself
# -----------------------------------------------------------------------------
# WHY IT LIVES IN THE PUBLIC SUBNET: This trips people up — the NAT Gateway
# SERVES the private subnets, but it physically sits IN a public subnet.
# That's because the NAT Gateway itself needs a route to the internet
# (via the IGW) to do its job of forwarding private-subnet traffic outward.
# It's the one deliberate "public subnet resource" that exists purely to
# help private subnets reach the internet, not to be reached FROM it.
# -----------------------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  count = var.single_nat_gateway ? 1 : length(var.availability_zones)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.cluster_name}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.main]
}


# -----------------------------------------------------------------------------
# RESOURCE 7: Public route table
# -----------------------------------------------------------------------------
# A route table is literally a list of rules: "traffic headed to THIS
# destination goes out THROUGH this gateway/device." This is the actual
# mechanism — not a label — that makes a subnet's traffic behave as
# "public" or "private."
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0" # "anywhere on the internet"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 8: Associate EVERY public subnet with the public route table
# -----------------------------------------------------------------------------
# A route table does nothing on its own until a subnet is explicitly
# associated with it. This is the step that actually "activates" the
# routing rule for each public subnet.
# -----------------------------------------------------------------------------
resource "aws_route_table_association" "public" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# RESOURCE 9: Private route table(s)
# -----------------------------------------------------------------------------
# WHY count HERE TOO: if single_nat_gateway = true, all private subnets
# share ONE route table, all pointing at the single NAT Gateway. If false
# (one NAT per AZ), we instead create ONE route table PER AZ, so each
# private subnet routes through the NAT Gateway physically sitting in ITS
# OWN AZ — keeping traffic from crossing AZ boundaries unnecessarily.
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = var.single_nat_gateway ? 1 : length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt-${count.index}"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 10: Associate EVERY private subnet with its private route table
# -----------------------------------------------------------------------------
resource "aws_route_table_association" "private" {
  count = length(var.availability_zones)

  subnet_id = aws_subnet.private[count.index].id
  # If single_nat_gateway, every private subnet points at route table [0].
  # Otherwise, private subnet[i] points at private route table[i] — its
  # own AZ's table.
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}
