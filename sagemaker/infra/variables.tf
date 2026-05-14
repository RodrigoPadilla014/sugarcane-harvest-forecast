variable "region" {
  default = "us-east-1"
}

variable "bucket_name" {
  default = "ndvi-extraction"
}

variable "job_submitter_user_name" {
  description = "IAM user name allowed to submit and manage TCH SageMaker training jobs."
  type        = string
}
