#! /usr/bin/env fish
# Beware: Things running inside unshare --mount with /nix remounted rw
# can easily mess up your system. Don't use this unless you're king of the castle.

sudo rm -rf /nix/var/cknix/
sudo rm -rf /nix/var/nix/gcroots/cknix/
sudo -E unshare --mount --fork fish -c '
mount -t btrfs -o rw,subvol=nix /dev/pool/nixos /nix
./createstore.py
'
