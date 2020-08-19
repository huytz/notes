#!/usr/bin/env bash
#
# Script to automatically add device to wg0
# Input: device name and ip.
#


#------------
# Main
#--------------------------

add(){

  # Suggest IP for new device
  suggestion

  local _confirm=""

  echo ":: Please enter device name and IP for auto gen configurations."

  read -p ":: Enter device name: " device
  read -p ":: Enter device IP: " ip

  read -p ":: Confirm to add device $device with IP: $ip to Wireguard ? (y/n): " _confirm \
    && [[ $_confirm == [yY] || $_confirm == [yY][eE][sS] ]] || exit 1

  echo -e "\n:: ...\n"

  # adding configuration
  addDeviceWithIP $device $ip

}

#------------
#
#--------------------------

# Suggest IP for new device
suggestion(){
  
  address=$(cat /etc/wireguard/wg0.conf | grep 'Address' |  awk '{ print $3 }')
  echo ":: Server address range IPs: $address"

  allocated=$(cat /etc/wireguard/wg0.conf | grep 'AllowedIPs' |  awk '{ print $3 }')
  echo ":: Allocated IPs: "
  echo "$allocated"
  
  echo ":: Please add next IP on ranges above !!!"
}

# Gen config
addDeviceWithIP(){

  device_name=$1 ; shift
  ip=$1 ; shift

  echo ":: Coppy new template configration..."
  cp -r /etc/wireguard/clients/device-template /etc/wireguard/clients/$device_name

  echo ":: Generating config for new device name $device_name..."

  echo ":: Creating key pair..."

  wg genkey | sudo tee /etc/wireguard/clients/$device_name/private | wg pubkey | sudo tee /etc/wireguard/clients/$device_name/public

  echo ":: Modify config..."

  private=$(cat /etc/wireguard/clients/"$device_name"/private)
  public=$(cat /etc/wireguard/clients/"$device_name"/public)

  echo $private

  local _template="/etc/wireguard/clients/$device_name/mobile.conf"

  sed -i "s/IP_TEMPLATE/$ip/g" $_template

  sed -i "s,DEVICE_PRVATE_KEY_TEMPLATE,$private,g" $_template

  echo ":: Add to Wireguard config..."
  
  # stop & start wireguard
  /usr/bin/systemctl stop wg-quick@wg0

  echo "[Peer]" >> /etc/wireguard/wg0.conf
  echo "PublicKey = $public" >> /etc/wireguard/wg0.conf
  echo "AllowedIPs = $ip" >> /etc/wireguard/wg0.conf

  /usr/bin/systemctl start wg-quick@wg0
  
  echo ":: Please scan this QR code using phone's camera..."
  echo "::."
  echo "::."
  echo "::."
  qrencode -t ansiutf8 < /etc/wireguard/clients/$device_name/mobile.conf
  echo "::."
  echo "::."
  echo "::End..."
  
}



#------------
# Run
#--------------------------

add
