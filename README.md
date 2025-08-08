# HPC Cluster Node Setup Scripts

This repository contains two Bash scripts that automate the process of adding compute nodes to a PBS Pro-based High Performance Computing (HPC) cluster.

---

## Overview

- **`export.sh`** — Run on the head node to export user, group, and shadow data for account synchronization.
- **`setup_node.sh`** — Run on a compute node to configure it, mount shared directories, sync users, set up SSH keys, and register the node with PBS Pro.

Both scripts are designed for **CentOS 7.9 Minimal** environments and assume NFS and PBS Pro are already set up on the head node.

---

## Features

### export.sh (Head Node)
- Creates `/home/sync/users.new`, `/home/sync/groups.new`, and `/home/sync/shadow.new` containing non-system accounts (UID/GID ≥ 1000).
- Ensures compute nodes can sync accounts without manual editing.
- Skips system accounts for safety.

### setup_node.sh (Compute Node)
- Sets a unique hostname.
- Configures Ethernet interface for autoconnect.
- Adjusts CentOS YUM repositories for local installation media.
- Mounts `/home` via NFS from the head node.
- Syncs `/etc/passwd`, `/etc/group`, and `/etc/shadow` from `/home/sync`.
- Copies `/etc/hosts` from the head node.
- Configures SSH key-based authentication for passwordless access from the head node.
- Installs and configures the PBS Pro execution package.
- Registers the node into a specified PBS queue.

---

## Requirements

- **CentOS 7.9 Minimal** or compatible system.
- Root access on both head and compute nodes.
- NFS configured between head and compute nodes:
  - `/home` for shared home directories.
- PBS Pro installed and configured on the head node.
  - The directory that contains the PSB packages must be in `/home/pbs/` on the Head node
   <img width="662" height="205" alt="image" src="https://github.com/user-attachments/assets/3787f62d-1c9e-4f2f-8744-c08174ff555c" />

---

## Usage

### 1. Prepare Sync Files on the Head Node
Run `export.sh` on the **head node**:
```bash
chmod +x export.sh
./export.sh
```

Expected Output
```bash
/home/sync/users.new
/home/sync/groups.new
/home/sync/shadow.new
```
<br>

### 2. Configure Compute Node

Run `setup_node.sh` on the compute node as root:
```bash
chmod +x setup_node.sh
./setup_node.sh <new-hostname> <head-node-ip>
```

Example
```bash
./setup_node.sh node01 192.168.56.101
```
---


### Arguments (setup_node.sh)
- new-hostname — The desired hostname for this compute node (e.g., node02).
- head-node-ip — The IP address of the head node.

---

# Credits
- This work was developed with the support of the Center of Excellence in High Performance Computing ([CEHPC](https://hpc.kau.edu.sa/Default-611997-EN)) during my summer internship.
- Special thanks to the staff at CEHPC:
```bash
  - Dr. Hany Elyamany
  - Dr. Ahmed Mahany
  - Eng. Ayman Shaheen
  - Eng. Abdullah Barghash
  - Eng. Mouhamad Mashat
```
- for their guidance, technical insights, and assistance in creating and testing these scripts.
