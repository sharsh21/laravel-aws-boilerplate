output "bucket_name" { value = aws_s3_bucket.main.id }
output "bucket_arn" { value = aws_s3_bucket.main.arn }
output "cloudfront_domain" { value = aws_cloudfront_distribution.main.domain_name }
