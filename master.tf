resource "hcloud_server" "first_control_plane" {
  name = "k3s-control-plane-0"

  image        = data.hcloud_image.linux.name
  rescue       = "linux64"
  server_type  = var.control_plane_server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.k3s.id]

  labels = {
    "provisioner" = "terraform",
    "engine"      = "k3s"
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/master.tpl", {
      name           = self.name
      ssh_public_key = local.ssh_public_key
      k3s_token      = random_password.k3s_token.result
      master_ip      = local.first_control_plane_network_ip
    })
    destination = "/tmp/config.yaml"

    connection {
      user        = "root"
      private_key = file(var.private_key)
      host        = self.ipv4_address
    }
  }


  provisioner "remote-exec" {
    inline = local.k3os_install_commands

    connection {
      user        = "root"
      private_key = file(var.private_key)
      host        = self.ipv4_address
    }
  }

  provisioner "local-exec" {
    command = <<-EOT
      sleep 60 && ping ${self.ipv4_address} | grep --line-buffered "bytes from" | head -1 && sleep 60 && scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.private_key} rancher@${self.ipv4_address}:/etc/rancher/k3s/k3s.yaml ${path.module}/kubeconfig.yaml
      sed -i -e 's/127.0.0.1/${self.ipv4_address}/g' ${path.module}/kubeconfig.yaml
    EOT
  }

  # Install the Hetzner Cloud cloud controller and cloud storage interface
  provisioner "local-exec" {
    command = <<-EOT
      kubectl -n kube-system create secret generic hcloud --from-literal=token=${var.hcloud_token} --from-literal=network=${hcloud_network.k3s.name} --kubeconfig ${path.module}/kubeconfig.yaml
      kubectl apply -f ${path.module}/manifests/hcloud-ccm-net.yaml --kubeconfig ${path.module}/kubeconfig.yaml
      kubectl -n kube-system create secret generic hcloud-csi --from-literal=token=${var.hcloud_token} --kubeconfig ${path.module}/kubeconfig.yaml
      kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/master/deploy/kubernetes/hcloud-csi.yml --kubeconfig ${path.module}/kubeconfig.yaml
    EOT
  }

  network {
    network_id = hcloud_network.k3s.id
    ip         = local.first_control_plane_network_ip
  }

  depends_on = [
    hcloud_network_subnet.k3s,
    hcloud_firewall.k3s
  ]
}