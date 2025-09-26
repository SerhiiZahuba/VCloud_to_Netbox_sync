#!/usr/bin/env python3
import os
import requests
import base64
import time
from datetime import datetime
import sys
from dotenv import load_dotenv

# === Завантаження .env ===
load_dotenv()

# === Конфіг з .env ===
VCLOUD_USER = os.getenv("VCLOUD_USER")
VCLOUD_PASS = os.getenv("VCLOUD_PASS")
VCLOUD_HOST = os.getenv("VCLOUD_HOST")

NETBOX_URL = os.getenv("NETBOX_URL")
NETBOX_TOKEN = os.getenv("NETBOX_TOKEN")

NETBOX_SITE = int(os.getenv("NETBOX_SITE", 0))
NETBOX_CLUSTER = int(os.getenv("NETBOX_CLUSTER", 0))
NETBOX_ROLE = int(os.getenv("NETBOX_ROLE", 0))
NETBOX_TENANT = int(os.getenv("NETBOX_TENANT", 0))
NETBOX_PLATFORM = int(os.getenv("NETBOX_PLATFORM", 0))

SYNC_TEMPLATES = os.getenv("SYNC_TEMPLATES", "false").lower() == "true"
SYNC_POWEROFF = os.getenv("SYNC_POWEROFF", "false").lower() == "true"

LOG_FILE = "sync_vms.log"


def log(msg: str):
    line = f"[{datetime.now().strftime('%F %T')}] {msg}"
    print(line)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


# === vCloud API ===
class VCloudClient:
    def __init__(self, host, user, password):
        self.host = host
        self.user = user
        self.password = password
        self.token = None
        self.headers = {}

    def login(self):
        creds = base64.b64encode(f"{self.user}:{self.password}".encode()).decode()
        headers = {
            "Authorization": f"Basic {creds}",
            "Accept": "application/*;version=38.1",
        }
        r = requests.post(f"{self.host}/cloudapi/1.0.0/sessions", headers=headers)
        if r.status_code != 200:
            log(f"❌ vCloud login failed (код {r.status_code})")
            sys.exit(1)
        self.token = r.headers.get("X-VMWARE-VCLOUD-ACCESS-TOKEN")
        if not self.token:
            log("❌ Не знайдено токен у відповіді")
            sys.exit(1)
        self.headers = {
            "Accept": "application/*+json;version=38.1",
            "Authorization": f"Bearer {self.token}",
        }
        log("✅ Авторизація у vCloud успішна")

    def test_connection(self):
        r = requests.get(f"{self.host}/api/query?type=vm&page=1&pageSize=1&format=records", headers=self.headers)
        if r.status_code != 200:
            log(f"❌ Помилка доступу до vCloud (код {r.status_code})")
            sys.exit(1)
        log("✅ Доступ до vCloud підтверджено")

    def list_vms(self, page=1, page_size=25):
        url = f"{self.host}/api/query?type=vm&page={page}&pageSize={page_size}&format=records"
        r = requests.get(url, headers=self.headers)

        if r.status_code == 400:
        # Кінець сторінок
            return []

        r.raise_for_status()
        return r.json().get("record", [])

    def get_vm_details(self, href):
        r = requests.get(href, headers=self.headers)
        r.raise_for_status()
        return r.json()


# === NetBox API ===
class NetboxClient:
    def __init__(self, url, token):
        self.url = url.rstrip("/")
        self.headers = {
            "Authorization": f"Token {token}",
            "Content-Type": "application/json",
        }

    def test_connection(self):
        r = requests.get(self.url + "/", headers=self.headers)
        if r.status_code != 200:
            log(f"❌ Помилка доступу до NetBox (код {r.status_code})")
            sys.exit(1)
        log("✅ Доступ до NetBox підтверджено")

    def find_vm(self, name):
        r = requests.get(f"{self.url}/virtualization/virtual-machines/?name={name}", headers=self.headers)
        data = r.json()
        return data["results"][0]["id"] if data.get("results") else None

    def create_vm(self, name, status, cpu, ram, disk, ip, ext_ip, mac, net):
        payload = {
            "name": name,
            "status": "active",
            "site": NETBOX_SITE,
            "cluster": NETBOX_CLUSTER,
            "role": NETBOX_ROLE,
            "tenant": NETBOX_TENANT,
            "platform": NETBOX_PLATFORM,
            "vcpus": cpu,
            "memory": ram,
            "disk": disk,
            "comments": "auto sync from cloud",
            "local_context_data": {
                "ip_address": ip,
                "external_ip": ext_ip,
                "mac": mac,
                "network": net,
                "cloud_status": status,
            },
        }
        r = requests.post(f"{self.url}/virtualization/virtual-machines/", headers=self.headers, json=payload)
        if r.status_code != 201:
            log(f"❌ Помилка створення VM {name}: {r.text}")
            return None
        return r.json()["id"]

    def update_vm(self, vm_id, status, cpu, ram, disk, ip, ext_ip, mac, net):
        payload = {
            "status": "active",
            "vcpus": cpu,
            "memory": ram,
            "disk": disk,
            "local_context_data": {
                "ip_address": ip,
                "external_ip": ext_ip,
                "mac": mac,
                "network": net,
                "cloud_status": status,
            },
        }
        requests.patch(f"{self.url}/virtualization/virtual-machines/{vm_id}/", headers=self.headers, json=payload)

    def create_interface(self, vm_id):
        payload = {
            "virtual_machine": vm_id,
            "name": "eth0",
            "enabled": True,
            "mtu": 65536,
            "mode": "access",
        }
        r = requests.post(f"{self.url}/virtualization/interfaces/", headers=self.headers, json=payload)
        return r.json().get("id")

    def create_ip(self, iface_id, ip):
        payload = {
            "status": "active",
            "assigned_object_type": "virtualization.vminterface",
            "assigned_object_id": iface_id,
            "address": f"{ip}/24",
            "family": 4,
        }
        r = requests.post(f"{self.url}/ipam/ip-addresses/", headers=self.headers, json=payload)
        return r.json().get("id")


# === Основна логіка ===
def main():
    vcloud = VCloudClient(VCLOUD_HOST, VCLOUD_USER, VCLOUD_PASS)
    netbox = NetboxClient(NETBOX_URL, NETBOX_TOKEN)

    vcloud.login()
    vcloud.test_connection()
    netbox.test_connection()

    page = 1
    while True:
        vms = vcloud.list_vms(page=page)
        if not vms:
            break

        for vm in vms:
            name = vm["name"]
            status = vm.get("status", "")
            cpu = vm.get("numberOfCpus", 0)
            ram = vm.get("memoryMB", 0)
            disk = vm.get("totalStorageAllocatedMb", 0)
            href = vm.get("href")
            is_template = vm.get("isVAppTemplate")

            if is_template and not SYNC_TEMPLATES:
                log(f"⏭ Пропущено шаблон {name}")
                continue
            if status == "POWERED_OFF" and not SYNC_POWEROFF:
                log(f"⏭ Пропущено вимкнену VM {name}")
                continue

            details = vcloud.get_vm_details(href)
            sections = [s for s in details.get("section", []) if s.get("_type") == "NetworkConnectionSectionType"]

            for conn in sections[0].get("networkConnection", []):
                ip = conn.get("ipAddress", "")
                ext_ip = conn.get("externalIpAddress", "")
                mac = conn.get("macAddress", "")
                net = conn.get("network", "")

                log(f"↘️ vCloud: {name} | {status} | CPU:{cpu} | RAM:{ram} | Disk:{disk} | IP:{ip} | Ext:{ext_ip} | MAC:{mac} | Net:{net}")

                vm_id = netbox.find_vm(name)
                if not vm_id:
                    vm_id = netbox.create_vm(name, status, cpu, ram, disk, ip, ext_ip, mac, net)
                    log(f"🆕 Створено VM {name} (ID: {vm_id})")
                else:
                    netbox.update_vm(vm_id, status, cpu, ram, disk, ip, ext_ip, mac, net)
                    log(f"♻️ Оновлено VM {name} (ID: {vm_id})")

                iface_id = netbox.create_interface(vm_id)
                if iface_id:
                    log(f"✅ Додано інтерфейс (Iface ID: {iface_id})")

                if ip:
                    ip_id = netbox.create_ip(iface_id, ip)
                    log(f"✅ Призначено IP {ip} (ID: {ip_id})")
                if ext_ip:
                    ext_ip_id = netbox.create_ip(iface_id, ext_ip)
                    log(f"✅ Призначено External IP {ext_ip} (ID: {ext_ip_id})")

            time.sleep(1)
        page += 1

    log("=== Синхронізація завершена ===")


if __name__ == "__main__":
    main()

