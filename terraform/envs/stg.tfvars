# Staging cluster. Deploys automatically on every stg-v* release - it is the
# rehearsal for prod, so it is deliberately the same shape as prod minus the
# approval gate and the extra replica.
#
#   make tf-apply ENV=stg IMAGE_TAG=stg-1.2.3
environment = "stg"
