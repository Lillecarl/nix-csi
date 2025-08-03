#! /usr/bin/env fish

sudo rm -rf /nix/var/cknix/
sudo -E unshare --mount --fork fish -c '
# sudo mount -o remount,rw /nix/store
sudo mount -t btrfs -o rw,subvol=nix /dev/pool/nixos /nix
# findmnt
./createstore.py
'
