terraform {
    required_providers {
        kubernetes = {
            source  = "hashicorp/kubernetes"
            version = "~> 2.0"
        }
    }
}

provider "kubernetes" {
    config_path = "~/.kube/config"
}

resource "kubernetes_namespace" "billing" {
    metadata {
        name = "billing"
    }
}

resource "kubernetes_deployment" "api_gateway" {
    metadata {
        name      = "api-gateway"
        namespace = kubernetes_namespace.billing.metadata[0].name
    }

    spec {
        replicas = 1

        selector {
            match_labels = {
                app = "api-gateway"
            }
        }

        template {
            metadata {
                labels = {
                    app = "api-gateway"
                }
            }

            spec {
                container {
                    image = "your-image:latest"
                    name  = "api-gateway"

                    port {
                        container_port = 8080
                    }
                }
            }
        }
    }
}

resource "kubernetes_service" "api_gateway" {
    metadata {
        name      = "api-gateway-service"
        namespace = kubernetes_namespace.billing.metadata[0].name
    }

    spec {
        selector = {
            app = "api-gateway"
        }

        port {
            port        = 80
            target_port = 8080
        }

        type = "LoadBalancer"
    }
}