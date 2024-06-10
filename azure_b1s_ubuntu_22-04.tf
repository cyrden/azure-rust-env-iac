provider "azurerm" {
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
}

resource "azurerm_resource_group" "personal_rg" {
  name     = "personal-azure-vm-rg"
  location = "North Europe"
}

resource "azurerm_virtual_network" "personal_vn" {
  name                = "personal-azure-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.personal_rg.location
  resource_group_name = azurerm_resource_group.personal_rg.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.personal_rg.name
  virtual_network_name = azurerm_virtual_network.personal_vn.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_interface" "personal_vm_nic" {
  name                = "personal-vm-nic"
  location            = azurerm_resource_group.personal_rg.location
  resource_group_name = azurerm_resource_group.personal_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.personal_vm_pip.id
  }

  depends_on = [azurerm_public_ip.personal_vm_pip, azurerm_subnet.internal]
}

resource "azurerm_public_ip" "personal_vm_pip" {
  name                = "personal-vm-pip"
  location            = azurerm_resource_group.personal_rg.location
  resource_group_name = azurerm_resource_group.personal_rg.name
  allocation_method   = "Dynamic"
}

resource "azurerm_network_security_group" "personal_vm_nsg" {
  name                = "personal-vm-nsg"
  location            = azurerm_resource_group.personal_rg.location
  resource_group_name = azurerm_resource_group.personal_rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "personal_vm_nsg_asso" {
  network_interface_id      = azurerm_network_interface.personal_vm_nic.id
  network_security_group_id = azurerm_network_security_group.personal_vm_nsg.id

  depends_on = [azurerm_network_interface.personal_vm_nic, azurerm_network_security_group.personal_vm_nsg]
}

resource "azurerm_linux_virtual_machine" "personal_vm" {
  name                = "personal-vm-ubuntu-22-04"
  resource_group_name = azurerm_resource_group.personal_rg.name
  location            = azurerm_resource_group.personal_rg.location
  size                = "Standard_B1s"
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.personal_vm_nic.id,
  ]

  os_disk {
    caching               = "ReadWrite"
    storage_account_type  = "Standard_LRS"
    disk_size_gb          = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  depends_on = [azurerm_network_interface_security_group_association.personal_vm_nsg_asso]
}

data "azurerm_public_ip" "data_personal_vm_pip" {
  name                = azurerm_public_ip.personal_vm_pip.name
  resource_group_name = azurerm_linux_virtual_machine.personal_vm.resource_group_name
}

resource "null_resource" "wait_for_ssh" {
  depends_on = [azurerm_linux_virtual_machine.personal_vm]

  provisioner "local-exec" {
    command = <<EOT
      IP=${data.azurerm_public_ip.data_personal_vm_pip.ip_address}
      echo "Waiting for SSH to be available at $IP..."
      while ! nc -z $IP 22; do
        echo "Waiting for SSH to be available..."
        sleep 5
      done
      echo "SSH is available at $IP"
    EOT
  }
}

resource "null_resource" "ansible_provision" {
  depends_on = [null_resource.wait_for_ssh]

  provisioner "local-exec" {
    command = <<EOT
      ansible-playbook -i '${data.azurerm_public_ip.data_personal_vm_pip.ip_address},' -u azureuser --private-key ~/.ssh/id_rsa install_rust.yml
    EOT
  } 
}

output "vm_public_ip" {
  value = data.azurerm_public_ip.data_personal_vm_pip.ip_address
}
