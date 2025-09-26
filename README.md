# 🌐 VCloud → Netbox Sync

A lightweight synchronization tool between **VMware vCloud Director** and **Netbox**.  
The goal is to keep Netbox up to date with virtual machines and templates from vCloud.

---

## 🔑 Requirements

Before running the sync, make sure you have the following:

### From vCloud
1. Username & password (create user in vCloud admin panel)
2. vCloud API URL
3. API token

### From Netbox
1. Netbox API URL
2. Netbox API token

---

## ✅ Current Features

- 🔒 **Access check**
  - Verify connection to **Netbox**
  - Verify connection to **vCloud**

- 💻 **VM Management**
  - Create **virtual machines** in Netbox:
    - Interfaces
    - Assigned IPs
    - CPU & Memory configuration

- 📦 **Template Synchronization**
  - Sync vCloud templates into Netbox
  - Can be disabled via configuration (`sync_templates=false`)

---

## 🚀 Roadmap / Plans

- 🔄 **Update existing VM data**  
  Keep Netbox in sync with real-time vCloud changes (IPs, CPUs, memory, interfaces)

- ⚡ **VM Status Tracking**  
  Synchronize power state (`ON/OFF`) from vCloud to Netbox

---

## ⚙️ Configuration

Main settings can be controlled via environment variables or config file.

Example `.env`:

```env
# VCloud
VCLOUD_URL=https://vcloud.example.com/api
VCLOUD_USER=api-user
VCLOUD_PASS=secret
VCLOUD_TOKEN=your-token

# Netbox
NETBOX_URL=https://netbox.example.com/api
NETBOX_TOKEN=your-netbox-token

# Options
SYNC_TEMPLATES=true
