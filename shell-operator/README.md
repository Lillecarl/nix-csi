# Shell-Operator Implementation for cknix

This directory contains a shell-operator implementation for watching cknix Expression CRD changes as an alternative to the kopf-based approach.

## Overview

Shell-operator is a Kubernetes tool that enables event-driven scripting by running hooks (shell scripts) in response to Kubernetes events. This implementation provides a simpler alternative to the Python-based kopf operator.

## Architecture

- **Hook**: `hooks/cknix-expression-watcher` - Main hook that watches for Expression CRD changes
- **Processor**: `process-expression.sh` - Placeholder script that processes expression changes
- **Deployment**: `deployment.yaml` - Kubernetes deployment for shell-operator
- **RBAC**: `rbac.yaml` - Role-based access control for CRD monitoring

## How It Works

1. Shell-operator runs in a Kubernetes pod
2. The hook is configured to watch `expressions.cknix.cool` custom resources
3. When an Expression CRD is added, modified, or deleted, the hook is triggered
4. The hook parses the binding context and calls the processing script
5. The processing script contains placeholder logic for handling the expression

## Hook Configuration

The hook uses this configuration to monitor Expression CRDs:

```yaml
configVersion: v1
kubernetes:
  - name: "cknix-expression-changes"
    kind: Expression
    apiVersion: cknix.cool/v1
    executeHookOnEvent: ["Added", "Modified", "Deleted"]
    namespace: {}
    jqFilter: ".spec.data.expr"
```

## Deployment

### Prerequisites

1. The cknix Expression CRD must be installed:
   ```bash
   kubectl apply -f ../yaml/crd.yaml
   ```

2. Shell-operator requires the custom resource to exist

### Install Shell-Operator

```bash
# Apply RBAC
kubectl apply -f rbac.yaml

# Deploy shell-operator
kubectl apply -f deployment.yaml
```

### Verify Installation

```bash
# Check deployment
kubectl get deployment shell-operator

# Check logs
kubectl logs deployment/shell-operator

# Test with a sample Expression
kubectl apply -f ../yaml/test/expression.yaml
```

## Hook Development

### Testing Hook Configuration

You can test the hook configuration locally:

```bash
# Test configuration output
./hooks/cknix-expression-watcher --config

# Test the processing script
./process-expression.sh "default" "test-expr" "ADDED" "pkgs.hello"
```

### Hook Structure

The hook handles three main cases:

1. **--config**: Returns YAML configuration for shell-operator
2. **Event Processing**: Processes CRD change events
3. **Synchronization**: Handles initial state synchronization

### Binding Context

Shell-operator provides event details in JSON format via `$BINDING_CONTEXT_PATH`. The hook parses this to extract:

- Event type (Added, Modified, Deleted)
- Object metadata (name, namespace)
- Expression data from the CRD spec

## Integration with Existing cknix

This shell-operator implementation is designed to:

- Monitor the same `expressions.cknix.cool` CRD as the kopf implementation
- Provide the same event handling capabilities
- Serve as a drop-in replacement for the kopf-based operator
- Maintain compatibility with existing YAML manifests

## Advantages of Shell-Operator

1. **Simplicity**: No Python dependencies, just shell scripts
2. **Flexibility**: Easy to modify hook behavior
3. **Debugging**: Easier to debug shell scripts than Python code
4. **Deployment**: Lighter weight than custom Python containers
5. **Familiarity**: Shell scripting is widely understood

## Customization

To extend the functionality:

1. **Modify the hook**: Edit `hooks/cknix-expression-watcher` to change monitoring behavior
2. **Update the processor**: Edit `process-expression.sh` to implement actual nix build logic
3. **Add more hooks**: Create additional hooks for different events
4. **Enhance RBAC**: Update `rbac.yaml` if additional permissions are needed

## Comparison with kopf

| Feature | kopf | shell-operator |
|---------|------|----------------|
| Language | Python | Shell/Any |
| Configuration | Code | YAML/JSON |
| Complexity | Higher | Lower |
| Debugging | Complex | Simple |
| Dependencies | Many | Few |
| Performance | Good | Good |
| Maintenance | Complex | Simple |

## Next Steps

1. Replace placeholder logic in `process-expression.sh` with actual nix build commands
2. Add error handling and retry logic
3. Implement status updates to the Expression CRD
4. Add metrics and monitoring
5. Test with real Expression CRDs in the cluster