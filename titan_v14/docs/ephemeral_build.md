# Ephemeral Build Machines — PROJECT HİDRA

## Amaç
Build ortamında kalıntı bırakmamak — compiler trojan / backdoor riski sıfır.

## Mimari
```
1. Cloud VM başlat (Ubuntu 22.04 minimal)
2. Docker pull hidra-build:latest
3. Source clone (air-gapped mirror)
4. Build → artifact export (SCP to signing server)
5. VM imha (terminate + disk wipe)
```

## Güvenlik Kuralları
- VM ömrü: max 2 saat
- Network: sadece internal registry (no internet)
- Disk: encrypted + shred after use
- No persistent SSH keys
- Build user: non-root, no sudo

## Terraform Örneği
```hcl
resource "aws_instance" "build" {
  ami           = "ami-hidra-build"
  instance_type = "c5.2xlarge"

  provisioner "local-exec" {
    when    = destroy
    command = "aws ec2 modify-instance-attribute --instance-id ${self.id} --block-device-mappings '[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"DeleteOnTermination\":true}}]'"
  }

  tags = { Purpose = "ephemeral-build", AutoDestroy = "true" }
}
```
