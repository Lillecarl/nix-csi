# Shell-Operator Usage Examples

This document provides examples of how to use the shell-operator implementation for cknix.

## Testing the Hook Locally

### 1. Test Hook Configuration

```bash
# Test that the hook outputs valid configuration
./hooks/cknix-expression-watcher --config

# Expected output:
# configVersion: v1
# kubernetes:
#   - name: "cknix-expression-changes"
#     kind: Expression
#     apiVersion: cknix.cool/v1
#     executeHookOnEvent: ["Added", "Modified", "Deleted"]
#     namespace: {}
#     jqFilter: ".spec.data.expr"
```

### 2. Test Processing Script

```bash
# Test the expression processor with sample data
./process-expression.sh "default" "hello-world" "ADDED" "pkgs.hello"

# Test different event types
./process-expression.sh "default" "hello-world" "MODIFIED" "pkgs.cowsay"
./process-expression.sh "default" "hello-world" "DELETED" ""
```

### 3. Run Complete Test Suite

```bash
# Run all tests
./test-hook.sh
```

## Deployment Examples

### 1. Deploy Shell-Operator

```bash
# Apply RBAC first
kubectl apply -f rbac.yaml

# Deploy shell-operator
kubectl apply -f deployment.yaml

# Check deployment status
kubectl get deployment shell-operator
kubectl get pods -l app=shell-operator
```

### 2. Monitor Hook Execution

```bash
# Watch shell-operator logs
kubectl logs deployment/shell-operator -f

# Check hook execution in real-time
kubectl logs deployment/shell-operator -f | grep "cknix Expression"
```

### 3. Test with Sample Expression

```bash
# Create a test expression
kubectl apply -f - <<EOF
apiVersion: cknix.cool/v1
kind: Expression
metadata:
  name: test-hello
  namespace: default
spec:
  data:
    expr: "pkgs.hello"
EOF

# Watch logs to see hook execution
kubectl logs deployment/shell-operator -f

# Clean up
kubectl delete expression test-hello
```

## Integration Examples

### 1. Replace kopf with Shell-Operator

```bash
# Scale down kopf-based operator
kubectl scale deployment cknix-deployment --replicas=0

# Deploy shell-operator
kubectl apply -f rbac.yaml
kubectl apply -f deployment.yaml

# Test with existing expressions
kubectl get expressions
```

### 2. Run Both Operators (for comparison)

```bash
# Deploy shell-operator alongside kopf
kubectl apply -f rbac.yaml
kubectl apply -f deployment.yaml

# Both operators will receive the same events
# Compare logs between them
kubectl logs deployment/cknix-deployment -f &
kubectl logs deployment/shell-operator -f &
```

## Binding Context Examples

### 1. Sample ADD Event

```json
[
  {
    "binding": "cknix-expression-changes",
    "type": "Event",
    "watchEvent": "ADDED",
    "object": {
      "apiVersion": "cknix.cool/v1",
      "kind": "Expression",
      "metadata": {
        "name": "my-package",
        "namespace": "default",
        "creationTimestamp": "2023-01-01T00:00:00Z"
      },
      "spec": {
        "data": {
          "expr": "pkgs.htop"
        }
      }
    }
  }
]
```

### 2. Sample MODIFIED Event

```json
[
  {
    "binding": "cknix-expression-changes",
    "type": "Event",
    "watchEvent": "MODIFIED",
    "object": {
      "apiVersion": "cknix.cool/v1",
      "kind": "Expression",
      "metadata": {
        "name": "my-package",
        "namespace": "default"
      },
      "spec": {
        "data": {
          "expr": "pkgs.neofetch"
        }
      }
    }
  }
]
```

### 3. Sample DELETED Event

```json
[
  {
    "binding": "cknix-expression-changes",
    "type": "Event",
    "watchEvent": "DELETED",
    "object": {
      "apiVersion": "cknix.cool/v1",
      "kind": "Expression",
      "metadata": {
        "name": "my-package",
        "namespace": "default"
      },
      "spec": {
        "data": {
          "expr": "pkgs.htop"
        }
      }
    }
  }
]
```

## Troubleshooting Examples

### 1. Hook Not Executing

```bash
# Check if CRD exists
kubectl get crd expressions.cknix.cool

# Check RBAC permissions
kubectl auth can-i get expressions.cknix.cool --as=system:serviceaccount:default:shell-operator

# Check hook configuration
kubectl logs deployment/shell-operator | grep -i config
```

### 2. Parsing Errors

```bash
# Check jq is available in container
kubectl exec deployment/shell-operator -- which jq

# Test binding context parsing
kubectl logs deployment/shell-operator | grep "Binding Context"
```

### 3. Permission Issues

```bash
# Check service account
kubectl get serviceaccount shell-operator

# Check cluster role binding
kubectl get clusterrolebinding shell-operator

# Test permissions
kubectl auth can-i list expressions.cknix.cool --as=system:serviceaccount:default:shell-operator
```

## Performance Examples

### 1. Monitor Resource Usage

```bash
# Check CPU/Memory usage
kubectl top pods -l app=shell-operator

# Check resource limits
kubectl describe pod -l app=shell-operator
```

### 2. Scaling Considerations

```bash
# Shell-operator typically runs as single replica
# For high availability, consider:
kubectl patch deployment shell-operator -p '{"spec":{"replicas":1}}'

# Monitor hook execution time
kubectl logs deployment/shell-operator | grep "execution completed"
```

## Advanced Examples

### 1. Multiple Namespaces

```bash
# Modify hook to watch specific namespaces
# Edit the hook configuration to include:
# namespace:
#   nameSelector:
#     matchNames: ["production", "staging"]
```

### 2. Custom Filtering

```bash
# Add label selector to hook configuration
# labelSelector:
#   matchLabels:
#     environment: "production"
```

### 3. Webhook Integration

```bash
# Hook can be extended to handle webhooks
# Add webhook configuration to deployment
# Configure admission controller integration
```