# ── ECR ─────────────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "hello_api" {
  name                 = "${var.prefix}/hello-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.lab.arn
  }
}

resource "aws_ecr_lifecycle_policy" "hello_api" {
  repository = aws_ecr_repository.hello_api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ── EKS (Floci runs a real k3s container per cluster) ───────────────────────
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks" {
  name               = "${var.prefix}-eks"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "lab" {
  name     = "${var.prefix}-eks"
  role_arn = aws_iam_role.eks.arn
  version  = "1.34"

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.lab.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]
  depends_on                = [aws_iam_role_policy_attachment.eks_cluster]
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy", "AmazonEC2ContainerRegistryReadOnly"])
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["t3.medium"]
  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }
  depends_on = [aws_iam_role_policy_attachment.node]
}

# ── ECS: cluster + task definition for hello-api from ECR ───────────────────
resource "aws_ecs_cluster" "lab" {
  name = "${var.prefix}-ecs"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.prefix}-hello-api"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.lab.arn
}

resource "aws_ecs_task_definition" "hello_api" {
  family                   = "${var.prefix}-hello-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  container_definitions = jsonencode([{
    name                   = "hello-api"
    image                  = "${aws_ecr_repository.hello_api.repository_url}:0.2.0"
    essential              = true
    readonlyRootFilesystem = true
    user                   = "65532:65532"
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    environment            = [{ name = "APP_ENV", value = "ecs" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "hello-api"
      }
    }
  }])
}
