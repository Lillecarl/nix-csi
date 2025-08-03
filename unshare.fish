#! /usr/bin/env fish

sudo rm -rf /nix/var/cknix/
sudo rm -rf /nix/var/nix/gcroots/cknix/
sudo -E unshare --mount --fork fish -c '
mount -t btrfs -o rw,subvol=nix /dev/pool/nixos /nix
./createstore.py
'
