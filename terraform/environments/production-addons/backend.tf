terraform {
  backend "s3" {
    bucket       = "campuscart-tfstate-021859068764"
    key          = "environments/production-addons/terraform.tfstate" # DIFFERENT key — separate state file, same bucket
    region       = "ap-south-1"
    use_lockfile = true
    encrypt      = true
  }
}
