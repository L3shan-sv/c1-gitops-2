resource "aws_ecr_repository" "myapp" {
  name                 = "${var.project}/myapp"
  image_tag_mutability = "IMMUTABLE" # Tags cannot be overwritten once pushed.

  image_scanning_configuration {
    scan_on_push = true # ECR scans for vulnerabilities on every push.
  }

  tags = var.tags
}

# Lifecycle policy — keep the last 30 tagged images per repo.
# Untagged images (build cache layers) are cleaned up after 1 day.
resource "aws_ecr_lifecycle_policy" "myapp" {
  repository = aws_ecr_repository.myapp.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}
