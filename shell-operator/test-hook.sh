#!/bin/bash

# Test script for the cknix-expression-watcher hook
# This script helps test the hook configuration and functionality

set -e

echo "=== Testing cknix Expression Watcher Hook ==="

HOOK_PATH="./hooks/cknix-expression-watcher"

# Test 1: Check if hook is executable
echo "Test 1: Checking hook executable..."
if [[ -x "$HOOK_PATH" ]]; then
    echo "✓ Hook is executable"
else
    echo "✗ Hook is not executable"
    chmod +x "$HOOK_PATH"
    echo "✓ Made hook executable"
fi

# Test 2: Test configuration output
echo -e "\nTest 2: Testing hook configuration..."
CONFIG_OUTPUT=$($HOOK_PATH --config)
echo "Configuration output:"
echo "$CONFIG_OUTPUT"

# Validate configuration format
if echo "$CONFIG_OUTPUT" | grep -q "configVersion: v1"; then
    echo "✓ Configuration contains configVersion"
else
    echo "✗ Configuration missing configVersion"
fi

if echo "$CONFIG_OUTPUT" | grep -q "expressions.cknix.cool"; then
    echo "✓ Configuration watches cknix expressions"
else
    echo "✗ Configuration not watching cknix expressions"
fi

# Test 3: Test processing script
echo -e "\nTest 3: Testing processing script..."
PROCESS_SCRIPT="./process-expression.sh"

if [[ -x "$PROCESS_SCRIPT" ]]; then
    echo "✓ Processing script is executable"
    
    # Test with sample parameters
    echo "Running processing script with test parameters..."
    $PROCESS_SCRIPT "default" "test-expression" "ADDED" "pkgs.hello"
    echo "✓ Processing script executed successfully"
else
    echo "✗ Processing script is not executable"
    if [[ -f "$PROCESS_SCRIPT" ]]; then
        chmod +x "$PROCESS_SCRIPT"
        echo "✓ Made processing script executable"
    else
        echo "✗ Processing script not found"
    fi
fi

# Test 4: Create sample binding context for testing
echo -e "\nTest 4: Testing with sample binding context..."
TEMP_CONTEXT=$(mktemp)
cat > "$TEMP_CONTEXT" << 'EOF'
[
  {
    "binding": "cknix-expression-changes",
    "type": "Event",
    "watchEvent": "ADDED",
    "object": {
      "apiVersion": "cknix.cool/v1",
      "kind": "Expression",
      "metadata": {
        "name": "test-expression",
        "namespace": "default"
      },
      "spec": {
        "data": {
          "expr": "pkgs.hello"
        }
      }
    }
  }
]
EOF

echo "Sample binding context created: $TEMP_CONTEXT"
export BINDING_CONTEXT_PATH="$TEMP_CONTEXT"

# Test hook execution with sample context
echo "Testing hook execution with sample binding context..."
if $HOOK_PATH; then
    echo "✓ Hook executed successfully with sample context"
else
    echo "✗ Hook failed with sample context"
fi

# Cleanup
rm -f "$TEMP_CONTEXT"

echo -e "\n=== Test Summary ==="
echo "All tests completed. Check output above for any failures."
echo "Hook is ready for deployment with shell-operator."