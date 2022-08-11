{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = inputs@{ self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    in
    {
      nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [{
          imports = [ "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix" ];
          environment.enableDebugInfo = true;
          services.xserver = {
            enable = true;
            desktopManager.cinnamon.enable = true;
          };
          users.users.test = {
            isNormalUser = true;
            uid = 1000;
            extraGroups = [ "wheel" "networkmanager" ];
            password = "test";
          };
          virtualisation = {
            qemu.options = [ "-device intel-hda -device hda-duplex" ];
            memorySize = 2048;
            diskSize = 8192;
          };
          system.stateVersion = "22.11";
        }];
      };
      checks = forAllSystems (system: self.packages.${system} // {
        cinnamon =
          with import ("${nixpkgs}/nixos/lib/testing-python.nix") { inherit system; };
          makeTest {
            name = "cinnamon-test";
            nodes.machine = { ... }: {
              imports = [ "${nixpkgs}/nixos/tests/common/user-account.nix" ];
              services.xserver.enable = true;
              services.xserver.displayManager = {
                lightdm.enable = true;
                defaultSession = "cinnamon";
                autoLogin = {
                  enable = true;
                  user = "alice";
                };
              };
              services.xserver.desktopManager.cinnamon.enable = true;
            };
            enableOCR = true;
            testScript = { nodes, ... }:
              let
                user = nodes.machine.config.users.users.alice;
              in
              ''
                def send_key(str):
                  machine.send_key(str)
                  machine.sleep(1)
                
                def send_chars(str):
                  machine.send_chars(str)
                  machine.sleep(2)

                machine.wait_for_x()
                machine.wait_for_file("${user.home}/.Xauthority")
                machine.succeed("xauth merge ${user.home}/.Xauthority")

                machine.wait_until_succeeds('pgrep -f cinnamon-session')
                machine.wait_until_succeeds('pgrep -f cinnamon-launcher')
                machine.wait_until_succeeds('pgrep -xf "cinnamon --replace"')
                machine.wait_until_succeeds('pgrep -f nemo-desktop')
                machine.wait_until_succeeds('pgrep -f csd-media-keys')

                with subtest("Basic"):
                  machine.wait_for_text("Computer")
                  machine.wait_for_text("Home")
                  machine.screenshot("1_desktop")

                with subtest("Nemo"):
                  machine.execute("su - ${user.name} -c 'DISPLAY=:0 nemo >&2 &'")
                  machine.wait_for_window("nemo")
                  machine.wait_for_text("My Computer")
                  send_key("ctrl-t") # new tab
                  send_key("ctrl-d") # new bookmark
                  send_key("ctrl-a") # select all
                  send_key("ctrl-c") # copy
                  send_key("ctrl-v") # paste
                  machine.wait_for_text("(copy)")
                  machine.screenshot("2_nemo")
                  machine.send_key('ctrl-q')

                with subtest("Settings"):
                  machine.execute("su - ${user.name} -c 'DISPLAY=:0 cinnamon-settings >&2 &'")
                  machine.wait_for_window("cinnamon-settings")
                  machine.wait_for_text("System Settings")
                  machine.screenshot("3_settings")
                  send_chars("System Info")
                  send_key("tab")
                  send_key("down")
                  send_key("\n")
                  machine.wait_for_text("Linux")
                  machine.screenshot("4_info")
                  machine.send_key('alt-f4')

                with subtest("Xed"):
                  machine.execute("su - ${user.name} -c 'DISPLAY=:0 xed >&2 &'")
                  machine.wait_for_window("xed")
                  machine.wait_for_text("Unsaved Document")
                  send_chars("Hello World")
                  machine.screenshot("5_xed")
                  send_key("ctrl-s")
                  machine.wait_for_text('Save')
                  send_chars("hello.txt")
                  send_key("\n")
                  machine.wait_for_file('/home/${user.name}/hello.txt')
                  machine.send_key('ctrl-q')

                with subtest("Lock"):
                  machine.execute("su - ${user.name} -c 'DISPLAY=:0 cinnamon-screensaver-command -l >&2 &'")
                  machine.sleep(5)
                  send_chars("${user.password}")
                  machine.screenshot("6_lock")
                  send_key("\n")
                  machine.wait_for_text("Computer")
              '';
          };
      });

      packages.x86_64-linux.default = self.nixosConfigurations.vm.config.system.build.vm;
      apps.x86_64-linux.default = {
        type = "app";
        program = "${self.packages.x86_64-linux.default}/bin/run-nixos-vm";
      };
    };
}
