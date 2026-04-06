ArgoCD Identity-Based Access:

The ArgoCD authentication flow is initiated via OIDC through a kubectl port-forward tunnel at http://localhost:8080
The argocd-server pod uses Azure Workload Identity. It projects a Kubernetes ServiceAccount token that is validated against the AKS OIDC Issuer URL via a Federated Credential trust relationship. 
Authorization is handled by the argocd-rbac-cm, which maps Entra ID groups to internal ArgoCD roles for an identity-based permission model.
 