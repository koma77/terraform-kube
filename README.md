# terraform-kube

This is an attempt to create a one node kubernetes cluster using tf + ansible tools

Ansilbe should create a kubectl config file, pls check certificates path with:

KUBECONFIG=kubectl\_config ./bin/kubectl config view
