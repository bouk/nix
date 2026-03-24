# A NixOS configuration for benchmarking nix eval performance.
# Target: ~5000 derivations in the closure.
{ lib, pkgs, ... }:
{
  boot.loader.grub.device = "/dev/sda";
  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
  system.stateVersion = "24.11";

  # ── Desktop (Xfce is lighter than GNOME/KDE) ───────────────────────────

  services.xserver.enable = true;
  services.xserver.desktopManager.xfce.enable = true;
  services.pipewire.enable = true;

  # ── Services ────────────────────────────────────────────────────────────

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
  };
  services.redis.servers.default.enable = true;
  services.nginx.enable = true;
  services.postfix.enable = true;
  services.openssh.enable = true;
  services.avahi.enable = true;
  virtualisation.docker.enable = true;
  networking.firewall.enable = true;
  networking.networkmanager.enable = true;

  # ── Packages ────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    vim neovim firefox
    git wget curl rsync tmux htop
    jq ripgrep fd bat
    gcc cmake ninja python3
    nmap
  ];

  fonts.enableDefaultPackages = true;
}
