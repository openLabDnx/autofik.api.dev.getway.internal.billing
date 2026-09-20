# Production cluster. A prod-v* release still fires the deploy, but the
# workflow's `production` GitHub Environment holds it until a reviewer
# approves - see .github/workflows/deploy.yml.
#
#   make tf-apply ENV=prod IMAGE_TAG=prod-1.2.3
environment = "prod"

# Three replicas (the default for prod in variables.tf) so losing one node
# still leaves two pods serving. Uncomment to override:
# replicas = 4

# Prod tracks `master` of this deploy repo like the other environments, which
# means a manifest commit reaches production as soon as it merges. When a
# release branch exists, pin it here:
# target_revision = "release"
