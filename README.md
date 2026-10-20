# Upgrading legacy Azure VMs in place

## The problem

Modernizing a legacy VM raises two questions: **can we change its hardware size without rebuilding the application or moving its data, and how much downtime should we expect?**

This repository documents a practical alternative to deploying a replacement VM: resize the existing Azure VM while retaining its resource identity and persistent disks. The upgrade concerns the **VM size**, not the operating system, Hyper-V generation, or disk controller.

There is also an allocation risk. If resizing requires deallocation, Azure releases the current compute allocation. The target size might then be unavailable, and returning to the old size is not guaranteed. The second part of the experiment addresses this with **On-demand Capacity Reservation before shutdown**.

## The experiment

On **October 20, 2026**, we tested `Standard_D1` and `Standard_D2_v2` moving to `Standard_D2ds_v5`. The target preserves the sources' Gen1/SCSI compatibility and includes temporary storage; it is a compatible test destination, not a universal sizing recommendation.

Each VM ran Ubuntu 22.04 and nginx. Its `/health` endpoint exposed application identity, a persistent payload hash, and boot metadata. Application data lived on the managed OS disk.

An independent PowerShell process on the Windows execution host probed HTTP **every second**, with an **800 ms timeout**. The observer was outside the tested VMs; its hosting infrastructure and location were not recorded. Access was restricted to its public IPv4 address on TCP 8080.

For each resize, we:

1. Recorded healthy baseline responses and VM, disk, network, and application identities.
2. Changed the VM size while monitoring continuously.
3. Verified application recovery, unchanged persistent identities and data, and the expected guest reboot.
4. Deleted the temporary resources and verified their absence.

### Results

| Region | Test | Control-plane duration | Observed HTTP downtime |
|---|---|---:|---:|
| South Africa North | Direct `D1` -> `D2ds_v5` | 40.90 s | **47.99 s** |
| South Africa North | Direct `D2_v2` -> `D2ds_v5` | 38.15 s | **30.99 s** |
| South Africa North | Reserved `D2_v2` -> `D2ds_v5`, VM 1 | 102.23 s | **102.01 s** |
| South Africa North | Reserved `D2_v2` -> `D2ds_v5`, VM 2 | 117.55 s | **116.99 s** |
| West Europe | Reserve two `D2ds_v5` slots, then create two VMs | Successful allocation | Not a resize |

**All four resizes preserved the VM resource, OS disk, NIC, static public IP, application identity, and payload. All four restarted the guest.** No application reinstallation was required.

The direct tests used `az vm resize` without explicit deallocation. The reserved tests used **deallocate -> resize -> associate -> start**. Their timings cover different procedures and do not isolate reservation overhead.

West Europe rejected creation of the legacy source VMs with `SkuNotAvailable`, so the full tests ran in South Africa North. The later West Europe test successfully reserved target capacity and created two VMs that consumed it. **It did not validate a legacy resize in West Europe.**

Downtime is measured from the first failed probe's start to the first recovered probe's start. These are sampled application observations, not guaranteed outage durations. Command completion is not application readiness: in the direct D1 test, HTTP recovered almost 16 seconds later.

## The precaution: reserve before stopping

Quota and SKU availability listings do not reserve hardware. A **Reserved Instance** provides a billing discount; an **On-demand Capacity Reservation** secures matching compute capacity under an SLA. Neither protects against guest or application startup failures.

The tested procedure for regional, standalone VMs is:

1. **Check compatibility and recovery:** target size, region/zone, quota, supported placement, and a tested backup/restore plan for production.
2. **Reserve the full target batch while sources remain running.** Require successful provisioning, matching size and placement, and enough free slots in both configured and runtime capacity.
3. **Recheck before each shutdown.** If the reservation or application baseline is not valid, do not stop the source.
4. **Deallocate, resize, associate, then start.** Verify the target size and explicit reservation-group association before starting; never substitute an unreserved start.
5. **Verify actual use and application recovery.** Confirm the VM appears in `virtualMachinesAllocated` and retains its persistent identities and payload.
6. **Release after acceptance:** set reserved quantity to zero, remove VM associations, and delete the reservation and its group. This does not require another deallocation.

In our tests, both slots were reserved before the first resize. Reservations were held for approximately **7 min 12 s** in South Africa North and **6 min 14 s** in West Europe, measured between capacity verification and quantity-zero verification. Release caused **no observed HTTP failures or guest reboots**.

On-demand reservations have **no minimum term commitment** and can be deleted after the test. Unused slots are billable, so running sources and unused target capacity incur costs simultaneously. A VM consuming its slot does not incur a second compute charge for that slot; disks and networking are separate. These scripts do not request scheduled Future or Block reservations.

**Production caveat:** retain useful reserved capacity and investigate if recovery fails. The disposable lab instead cleans up everything it created, even on failure. Availability Sets and other unsupported placements require a different approach; the script does not implement zonal migrations.

## Reproduce the tests

Requires **Windows, PowerShell 7, Azure CLI, Bicep CLI, OpenSSH `ssh-keygen`**, an authenticated subscription with sufficient permissions/quota, and a stable public IPv4 address for the observer.

**These commands create billable resources, interrupt test applications, and delete their resource groups afterward. They are not production migration scripts.**

```powershell
$configDir = 'C:\.AutenticazioneCLI\<environment>\.azure'
$env:AZURE_CONFIG_DIR = $configDir
az account show

# Direct resize: one D1 and one D2_v2.
.\scripts\Invoke-Lab.ps1 `
  -ConfigDir $configDir -SubscriptionId '<subscription-id>' `
  -Regions @('westeurope', 'southafricanorth')

# Reserve two target slots, then resize two D2_v2 VMs sequentially.
.\scripts\Invoke-ReservedResizeLab.ps1 `
  -ConfigDir $configDir -SubscriptionId '<subscription-id>' `
  -Quantity 2 -SourceSize Standard_D2_v2 `
  -Regions @('westeurope', 'southafricanorth')

# Partial test: reserve first, then create target VMs in West Europe.
.\scripts\Invoke-ReservedResizeLab.ps1 `
  -ConfigDir $configDir -SubscriptionId '<subscription-id>' `
  -Quantity 2 -Regions @('westeurope') -TargetAllocationOnly
```

Both scripts check the active subscription. The reserved script fixes the target to `Standard_D2ds_v5` and supports `Standard_D1`, `Standard_D2_v2`, or `Standard_D2s_v3` sources. Its regional fallback is allowed only for capacity failures **before any resize starts**, after failed-attempt cleanup. Supply only `westeurope` to forbid fallback.

### Local validation and analysis

```powershell
az bicep build --file .\infra\main.bicep --stdout | Out-Null
.\tests\Test-Monitor.ps1
.\tests\Test-Analysis.ps1
.\tests\Test-CapacityReservation.ps1
.\tests\Test-LabCommon.ps1

# Recompute published direct-resize measurements without Azure access.
.\scripts\Analyze-Results.ps1 -EvidencePath '.\results\resize-20261020-101252'
```

For a new resize run, point the analyzer to its directory under `evidence/`; use `-ExpectedExperiments <quantity>` for batches other than two. Target-only allocation records are not resize inputs. Mocked tests validate safety gates and command ordering, not regional capacity.

## Evidence and implementation

| Resource | Contents |
|---|---|
| [Direct-resize evidence](results/resize-20261020-101252/) | Sanitized probes, identities, guest/disk diagnostics, timings, and latency statistics |
| [Capacity-reservation results](results/capacity-reservation-20261020/summary.json) | Curated full-resize and West Europe allocation measurements |
| [VM template](infra/main.bicep) and [cloud-init](infra/cloud-init.yaml) | Infrastructure and persistent nginx test application |
| [Direct lab](scripts/Invoke-Lab.ps1) and [reserved lab](scripts/Invoke-ReservedResizeLab.ps1) | Deployment, measurement, verification, and cleanup |
| [Observer](scripts/Monitor-Http.ps1) and [analyzer](scripts/Analyze-Results.ps1) | HTTP sampling and downtime calculation |
| [Reservation helpers](scripts/CapacityReservation.ps1) and [shared helpers](scripts/Lab-Common.ps1) | Capacity gates, association/release, CLI execution, and health checks |
| [Optional metrics](scripts/Collect-LabMetrics.ps1), [exporter](scripts/Export-PublicationEvidence.ps1), [tests](tests/) | Platform metrics, curated publication, and local validation |

All **nine resource groups** across the original and reservation experiments were deleted and independently verified absent. Temporary keys and observers were removed.

Raw evidence and authentication state stay in ignored `evidence/` and `.azure/` directories. The exporter supports only the original two-experiment schema; reservation results require separate curation. Published identifiers are pseudonymized. In the original result files, `hyperVGeneration` contains an image SKU; separate disk metadata confirms `V1`.

## Conclusion

**A compatible in-place resize can preserve an installed application and its persistent OS-disk data, but it remains a disruptive operation.** Reserving target capacity before shutdown mitigates allocation risk; it does not eliminate downtime or replace recovery planning.

These low-load nginx tests do not establish database consistency, temporary/data-disk persistence, or production outage bounds. If prolonged interruption is unacceptable, use an already-running replacement and a data-consistent traffic-switching plan. After an accepted production resize, update the VM's desired size in IaC.

### Microsoft references

- [Modernization destinations](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) and [resize compatibility](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/resize-vm)
- [On-demand capacity reservation: support, billing, and SLA](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview)
- [Associate an existing VM](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-associate-vm) and [resize within a reservation group](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-modify)
- [Release without deallocating the VM](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-remove-vm#update-the-reserved-quantity-to-zero)
