# Development cluster. Deploys automatically on every dev-v* release from the
# app repo, with no approval gate.
#
#   make tf-apply ENV=dev IMAGE_TAG=dev-1.2.3
environment = "dev"
