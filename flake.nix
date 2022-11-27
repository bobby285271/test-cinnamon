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
        modules = [
          ({ pkgs, ... }: {
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
            environment.systemPackages = [ ];
            system.stateVersion = "22.11";
          })
        ];
      };
      checks = forAllSystems (system: self.packages.${system} // {
        cinnamon =
          with import ("${nixpkgs}/nixos/lib/testing-python.nix") { inherit system; };
          makeTest {
            name = "cinnamon-test";
            nodes.machine = { ... }: {
              imports = [ "${nixpkgs}/nixos/tests/common/user-account.nix" ];
              services.xserver.enable = true;
              services.xserver.desktopManager.cinnamon.enable = true;
            };
            enableOCR = true;
            testScript = { nodes, ... }:
              let
                user = nodes.machine.config.users.users.alice;
                uid = toString user.uid;
                bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus";
                display = "DISPLAY=:0.0";
                env = "${bus} ${display}";
                gdbus = "${env} gdbus";
                su = command: "su - ${user.name} -c '${env} ${command}'";

                # Call javascript in cinnamon (the shell), returns a tuple (success, output),
                # where `success` is true if the dbus call was successful and `output` is what
                # the javascript evaluates to.
                eval = "call --session -d org.Cinnamon -o /org/Cinnamon -m org.Cinnamon.Eval";

                # Should be 2 (RunState.RUNNING) when startup is done.
                # https://github.com/linuxmint/cinnamon/blob/5.4.0/js/ui/main.js#L183-L187
                getRunState = su "${gdbus} ${eval} Main.runState";

                # Start gnome-terminal.
                gnomeTerminalCommand = su "gnome-terminal";

                # Hopefully gnome-terminal's wm class.
                wmClass = su "${gdbus} ${eval} global.display.focus_window.wm_class";
              in
              ''
                machine.wait_for_unit("display-manager.service")
                with subtest("Test if we can see username in slick-greeter"):
                    machine.wait_for_text("${user.description}")
                    machine.screenshot("slick_greeter_lightdm")
                with subtest("Login with slick-greeter"):
                    machine.send_chars("${user.password}\n")
                    machine.wait_for_x()
                    machine.wait_for_file("${user.home}/.Xauthority")
                    machine.succeed("xauth merge ${user.home}/.Xauthority")
                with subtest("Check that logging in has given the user ownership of devices"):
                    machine.succeed("getfacl -p /dev/snd/timer | grep -q ${user.name}")
                with subtest("Wait for the Cinnamon shell"):
                    # Correct output should be (true, '2')
                    machine.wait_until_succeeds("${getRunState} | grep -q 'true,..2'")
                with subtest("Open GNOME Terminal"):
                    machine.succeed("${gnomeTerminalCommand}")
                    # Correct output should be (true, '"Gnome-terminal"')
                    machine.wait_until_succeeds("${wmClass} | grep -q 'true,...Gnome-terminal'")
                    machine.sleep(20)
                    machine.screenshot("screen")

                # Extra tests

                def send_key(str):
                  machine.send_key(str)
                  machine.sleep(2)
                
                def send_chars(str):
                  machine.send_chars(str)
                  machine.sleep(3)

                machine.wait_for_x()
                machine.wait_for_file("${user.home}/.Xauthority")
                machine.succeed("xauth merge ${user.home}/.Xauthority")

                machine.wait_until_succeeds('pgrep -f cinnamon-session')
                machine.wait_until_succeeds('pgrep -f cinnamon-launcher')
                machine.wait_until_succeeds('pgrep -f "cinnamon --replace"')
                machine.wait_until_succeeds('pgrep -f nemo-desktop')
                machine.wait_until_succeeds('pgrep -f csd-media-keys')

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
                  machine.wait_for_text("${user.description}")
                  machine.screenshot("6_lock")
                  send_key("\n")
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
