variable "project"          { type = string }
variable "environment"      { type = string }
variable "oidc_provider_arn" { type = string }
variable "tags"             { type = map(string) default = {} }

output "myapp_role_arn"                  { value = module.myapp_irsa.iam_role_arn }
output "jenkins_role_arn"               { value = module.jenkins_irsa.iam_role_arn }
output "argocd_image_updater_role_arn"  { value = module.argocd_image_updater_irsa.iam_role_arn }
