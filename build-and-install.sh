#!/usr/bin/env bash

# Script to build a derivation and install it with its build inputs
# in /nix/var/nix/gcroots/drvname/

set -e

# Usage function
usage() {
    echo "Usage: $0 <derivation_path_or_flake_attr>"
    echo "Example: $0 .#nix2containerImage"
    echo "Example: $0 /nix/store/...-some-derivation.drv"
    echo ""
    echo "Note: This script requires sudo access to create gcroots in /nix/var/nix/gcroots"
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    usage
fi

DERIVATION="$1"

# Function to get derivation name from store path
get_drv_name() {
    local drv_path="$1"
    basename "$drv_path" | sed 's/\.drv$//'
}

# Function to get all build inputs recursively
get_build_inputs() {
    local drv_path="$1"
    echo "Getting build inputs for: $drv_path" >&2
    
    # Query the derivation for its inputs
    nix-store --query --requisites "$drv_path" 2>/dev/null || {
        echo "Warning: Could not query requisites for $drv_path" >&2
        return 0
    }
}

# Build the derivation and get its store path
echo "Building derivation: $DERIVATION"
if [[ "$DERIVATION" == *.drv ]]; then
    # Direct .drv file
    DRV_PATH="$DERIVATION"
    STORE_PATH=$(nix-store --realise "$DRV_PATH")
else
    # Flake attribute or other expression
    echo "Building and getting derivation path..."
    STORE_PATH=$(nix build "$DERIVATION" --no-link --print-out-paths)
    DRV_PATH=$(nix path-info --derivation "$STORE_PATH")
fi

echo "Derivation path: $DRV_PATH"
echo "Store path: $STORE_PATH"

# Get derivation name
DRV_NAME=$(get_drv_name "$DRV_PATH")
echo "Derivation name: $DRV_NAME"

# Create gcroots directory structure
GCROOT_DIR="/nix/var/nix/gcroots/$DRV_NAME"
echo "Creating gcroots directory: $GCROOT_DIR"
sudo mkdir -p "$GCROOT_DIR"

# Create symlink for the main derivation output
echo "Creating symlink for main output..."
sudo ln -sf "$STORE_PATH" "$GCROOT_DIR/result"

# Get and install all build inputs
echo "Getting build inputs..."
BUILD_INPUTS=$(get_build_inputs "$DRV_PATH")

if [ -n "$BUILD_INPUTS" ]; then
    echo "Installing build inputs..."
    
    # Create subdirectory for inputs
    sudo mkdir -p "$GCROOT_DIR/inputs"
    
    # Counter for numbering inputs
    counter=1
    
    # Process each build input
    while IFS= read -r input; do
        if [ -n "$input" ] && [ "$input" != "$DRV_PATH" ]; then
            input_name=$(basename "$input")
            echo "  Installing input $counter: $input_name"
            
            # Create numbered symlink for this input
            sudo ln -sf "$input" "$GCROOT_DIR/inputs/$(printf "%03d" $counter)-$input_name"
            counter=$((counter + 1))
        fi
    done <<< "$BUILD_INPUTS"
    
    echo "Installed $((counter - 1)) build inputs"
else
    echo "No build inputs found or could not query them"
fi

# Also get runtime dependencies of the built result
echo "Getting runtime dependencies..."
if [ -e "$STORE_PATH" ]; then
    RUNTIME_DEPS=$(nix-store --query --references "$STORE_PATH" 2>/dev/null || echo "")
    
    if [ -n "$RUNTIME_DEPS" ]; then
        echo "Installing runtime dependencies..."
        
        # Create subdirectory for runtime deps
        sudo mkdir -p "$GCROOT_DIR/runtime"
        
        counter=1
        while IFS= read -r dep; do
            if [ -n "$dep" ] && [ "$dep" != "$STORE_PATH" ]; then
                dep_name=$(basename "$dep")
                echo "  Installing runtime dep $counter: $dep_name"
                
                # Create numbered symlink for this dependency
                sudo ln -sf "$dep" "$GCROOT_DIR/runtime/$(printf "%03d" $counter)-$dep_name"
                counter=$((counter + 1))
            fi
        done <<< "$RUNTIME_DEPS"
        
        echo "Installed $((counter - 1)) runtime dependencies"
    else
        echo "No runtime dependencies found"
    fi
fi

# Set proper ownership
echo "Setting ownership..."
sudo chown -R root:root "$GCROOT_DIR"

# Display summary
echo ""
echo "Installation complete!"
echo "Derivation: $DRV_NAME"
echo "Location: $GCROOT_DIR"
echo "Contents:"
sudo find "$GCROOT_DIR" -type l -exec ls -la {} \; | head -20
if [ $(sudo find "$GCROOT_DIR" -type l | wc -l) -gt 20 ]; then
    echo "... ($(sudo find "$GCROOT_DIR" -type l | wc -l) total symlinks)"
fi