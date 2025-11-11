#!/bin/bash

# Function to display error message and exit
display_error() {
  echo "Error: $1" >&2
  exit 1
}

# Function to execute a command and handle errors, with optional internet connectivity check
execute_command() {
  local check_internet="$2"  # Check for internet if this argument is provided

  echo "Executing: $1"

  if [ "$check_internet" = "check_internet" ]; then
    local max_retries=18  # Total number of retries (18 retries * 10 seconds = 3 minutes)
    local retry_interval=10  # Retry interval in seconds

    for ((attempt = 1; attempt <= max_retries; attempt++)); do
      # Check for internet connectivity
      if ping -q -c 1 -W 1 google.com &>/dev/null; then
        # Internet is available, execute the command
        eval "$1"
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
          return 0  # Command executed successfully
        else
          echo "Command failed with exit code $exit_code."
          sleep $retry_interval  # Wait before retrying
        fi
      else
        echo "Internet not available, retrying in $retry_interval seconds (Attempt $attempt/$max_retries)..."
        sleep $retry_interval  # Wait before retrying
      fi
    done

    echo "Command failed after $((max_retries * retry_interval)) seconds of retries."
    exit 1  # Exit the script after multiple unsuccessful retries
  else
    eval "$1"  # Execute the command without internet connectivity check
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
      echo "Command failed with exit code $exit_code."
    fi
  fi
}



# Function to update the OS
update_os() {
  execute_command "sudo apt-get update" "check_internet"
  execute_command "sudo apt-get upgrade -y"
}

# Function to create and configure the autoconnect script
configure_autoconnect_script() {
  # Create connectall.py file
  cat <<EOF | sudo tee /usr/local/bin/connectall.py > /dev/null
#!/usr/bin/python3
import subprocess

ports = subprocess.check_output(["aconnect", "-i", "-l"], text=True)
port_list = []
client = "0"
for line in str(ports).splitlines():
    if line.startswith("client "):
        client = line[7:].split(":",2)[0]
        if client == "0" or "Through" in line:
            client = "0"
    else:
        if client == "0" or line.startswith('\t'):
            continue
        port = line.split()[0]
        port_list.append(client+":"+port)
for source in port_list:
    for target in port_list:
        if source != target:
            subprocess.call("aconnect %s %s" % (source, target), shell=True)
EOF
  execute_command "sudo chmod +x /usr/local/bin/connectall.py"

  # Create udev rules file
  echo 'ACTION=="add|remove", SUBSYSTEM=="usb", DRIVER=="usb", RUN+="/usr/local/bin/connectall.py"' | sudo tee -a /etc/udev/rules.d/33-midiusb.rules > /dev/null

  # Reload services
  execute_command "sudo udevadm control --reload"
  execute_command "sudo service udev restart"

  # Create midi.service file
  cat <<EOF | sudo tee /lib/systemd/system/midi.service > /dev/null
[Unit]
Description=Initial USB MIDI connect

[Service]
ExecStart=/usr/local/bin/connectall.py

[Install]
WantedBy=multi-user.target
EOF

  # Reload daemon and enable service
  execute_command "sudo systemctl daemon-reload"
  execute_command "sudo systemctl enable midi.service"
  execute_command "sudo systemctl start midi.service"
}

# Function to enable SPI interface
enable_spi_interface() {
  # !!! FIX FOR DEBIAN: 'raspi-config' is NOT installed on generic Debian images.
  # The goal is likely to enable SPI in the boot config.
  # On generic Debian, this is handled via device tree or kernel modules.
  # We will skip the raspi-config command, as it will likely fail on non-Raspberry Pi OS.
  # On a desktop Debian, you'd typically load the module:
  # execute_command "sudo modprobe spi_bcm2835"
  # Since this is likely a Debian on a Pi, we'll try editing config.txt directly if it exists.
  if [ -f "/boot/config.txt" ]; then
    echo "Attempting to enable SPI in /boot/config.txt (assuming Debian on Pi)..."
    # Ensure dtparam=spi=on is present, or add it.
    if ! grep -q "dtparam=spi=on" /boot/config.txt; then
      execute_command "echo 'dtparam=spi=on' | sudo tee -a /boot/config.txt"
    fi
  else
    echo "Warning: /boot/config.txt not found. Skipping SPI configuration."
  fi
}

# --- START OF FIXES ---

# Function to install required packages (UPDATED for modern OS compatibility)
install_packages() {
  # FIXES for Debian:
  # - libfmt-dev is the correct modern package.
  # - libopenblas-dev is preferred over libatlas-base-dev.
  # - libtiff5 is kept as the user reported needing it (often the case for older compiled software).
  # - Removed 'libgcc-s1' and 'libc6' as they are base system packages and shouldn't be installed this way.
  # - Added 'libwebp-dev' which is often needed alongside TIFF/JPEG/OpenJP2
  # - Added 'libjpeg-dev' (required by Pillow/Visualizer on some systems)
  execute_command "sudo apt-get install -y ruby git python3-pip autotools-dev libtool autoconf libasound2 libavahi-client3 libavahi-common3 libfmt-dev python3 libopenblas-dev libavahi-client-dev libasound2-dev libusb-dev libdbus-1-dev libglib2.0-dev libudev-dev libical-dev libreadline-dev libopenjp2-7 libtiff5 libjack0 libjack-dev fonts-freefont-ttf gcc make build-essential scons swig abcmidi libjpeg-dev libwebp-dev" "check_internet"
}

# Function to disable audio output
disable_audio_output() {
  # This part is fine if using a Raspberry Pi kernel module (snd_bcm2835).
  echo 'blacklist snd_bcm2835' | sudo tee -a /etc/modprobe.d/snd-blacklist.conf > /dev/null
  
  # FIX: Only attempt to edit /boot/config.txt if it exists.
  if [ -f "/boot/config.txt" ]; then
    sudo sed -i 's/dtparam=audio=on/#dtparam=audio=on/' /boot/config.txt
  else
    echo "Warning: /boot/config.txt not found. Skipping audio configuration in boot config."
  fi
}

# Function to install RTP-midi server (REMOVED manual libfmt9 download)
install_rtpmidi_server() {
  execute_command "cd /home/"
  # FIX: The armhf architecture is for 32-bit systems (like Raspberry Pi OS 32-bit).
  # If you are running a 64-bit Debian image on your Pi, you will need the arm64 (aarch64) package.
  # For generality, we will use the armhf version as it's the most common default on Pi-based Debian.
  # If this fails, the user must manually change the URL to the arm64 package if running 64-bit OS.
  execute_command "sudo wget https://github.com/davidmoreno/rtpmidid/releases/download/v24.12/rtpmidid_24.12.2_armhf.deb" "check_internet"
  execute_command "sudo dpkg -i rtpmidid_24.12.2_armhf.deb"
  execute_command "sudo apt -f install" # Now relies on the system to resolve dependencies using the repositories
  execute_command "rm rtpmidid_24.12.2_armhf.deb"
}

# --- END OF FIXES ---


# Function to install Piano-LED-Visualizer
install_piano_led_visualizer() {
  execute_command "cd /home/"
  execute_command "sudo git clone https://github.com/onlaj/Piano-LED-Visualizer" "check_internet"
  execute_command "sudo chown -R $USER:$USER /home/Piano-LED-Visualizer"
  execute_command "sudo chmod -R u+rwx /home/Piano-LED-Visualizer"
  execute_command "cd Piano-LED-Visualizer"
  # The --break-system-packages flag is for newer Debian/Ubuntu and is necessary to install system-wide.
  execute_command "sudo pip3 install -r requirements.txt --break-system-packages" "check_internet"
  
  # FIX FOR DEBIAN: 'raspi-config nonint do_boot_behaviour' will fail.
  # This command is meant to set the system to boot to desktop/GUI. Skipping this.
  # If a GUI is needed, the user must configure it manually.
  echo "Skipping raspi-config boot behavior setting (Debian compatibility)."
  
  # Ensure the visualizer user/group exist before creating the service
  execute_command "sudo groupadd -r plv || true"
  execute_command "sudo useradd -r -g plv -s /sbin/nologin plv || true"
  
  cat <<EOF | sudo tee /lib/systemd/system/visualizer.service > /dev/null
[Unit]
Description=Piano LED Visualizer
After=network-online.target
Wants=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
# FIX: Run as root for system-wide service
ExecStart=/usr/bin/python3 /home/Piano-LED-Visualizer/visualizer.py
Restart=always
Type=simple
# User=plv
# Group=plv
EOF
  execute_command "sudo systemctl daemon-reload"
  execute_command "sudo systemctl enable visualizer.service"
  execute_command "sudo systemctl start visualizer.service"

  execute_command "sudo chmod a+rwxX -R /home/Piano-LED-Visualizer/"
}

finish_installation() {
  echo "------------------"
  echo "------------------"
  echo "Installation complete. Debian image will automatically restart in 60 seconds."
  echo "If the system does not restart on its own, please wait for 2 minutes and then manually reboot."
  echo "After the reboot, please wait for up to 10 minutes. The Visualizer should start, and the Hotspot 'PianoLEDVisualizer' will become available (if networking is configured)."

  execute_command "sudo shutdown -r +1"
  sleep 60
  # Reboot system
  execute_command "sudo reboot"
}

echo "
#    _____  _                        _       ______  _____
#   |  __ \\(_)                      | |     |  ____||  __ \\
#   | |__) |_   __ _  _ __    ___   | |     | |__   | |  | |
#   |  ___/| | / _\` || '_ \\  / _ \\  | |     |  __|  | |  | |
#   | |    | || (_| || | | || (_) | | |____ | |____ | |__| |
#   |_|    |_| \\__,_||_| |_| \\___/  |______||______||_____/
#   __      __ _                     _  _
#   \\ \\    / /(_)                   | |(_)
#    \\ \\  / /  _  ___  _   _   __ _ | | _  ____ ___  _ __
#     \\ \\/ /  | |/ __|| | | | / _\` || || ||_  // _ \\| '__|
#      \\  /   | |\\__ \\| |_| || (_| || || | / /|  __/| |
#       \\/    |_||___/ \\__,_| \\__,_||_||_|/___|\\___||_|
#
# Autoinstall script
# - by Onlaj
"

# Main script execution
update_os
configure_autoconnect_script
enable_spi_interface
install_packages
disable_audio_output
install_rtpmidi_server
install_piano_led_visualizer
finish_installation