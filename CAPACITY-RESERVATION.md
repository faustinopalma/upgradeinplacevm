# Capacity-reserved in-place resize

## Why reserve capacity?

Deallocating a VM releases its compute allocation. Neither the target size nor a return to the original size is then assured. Reserve the target capacity **before stopping the source**, and explicitly associate the VM with that reservation before starting it.

Quota and SKU listings do not reserve hardware. Neither does a Reserved Instance, which provides a billing discount. An **On-demand Capacity Reservation** protects capacity under an SLA, not guest or application recovery.

## Duration and cost

On-demand reservations have **no minimum term commitment** and can be deleted after the test. The script does not request scheduled Future or Block reservations.

Unused reserved slots are billable. While sources run and target slots are unused, both incur charges; a VM consuming its reserved slot does not incur a second compute charge for that slot. Disks and networking are billed separately. The test releases capacity after validation; measured elapsed time is not a final invoice.

## Methodology

1. **Preflight:** verify backups and restore, OS/disk compatibility, target size, region/zone, and quota for sources plus reserved targets. Check placement support; Availability Sets, for example, are unsupported.
2. **Capture the baseline:** keep sources running; record VM, disk, network, application, payload, and boot identities.
3. **Reserve the whole batch:** require `Succeeded`, matching placement/size, and enough free slots in both configured and runtime capacity. Start external HTTP monitoring and require a healthy baseline.
4. **Gate and resize each VM:** recheck remaining slots, then deallocate, resize while deallocated, associate with the reservation group, verify the association, and start. A failed gate means **no source shutdown**; never fall back to an unreserved start.
5. **Accept recovery:** confirm `virtualMachinesAllocated` contains the VM, the application is healthy, persistent identities/hash are unchanged, and the guest rebooted.
6. **Release:** with monitoring active, set reserved quantity to zero, remove VM associations, and delete the reservation and its group. Verify application continuity and unchanged boot IDs; no second deallocation is needed.

For production, a failed resize or application check calls for retaining useful reserved capacity and investigating. The disposable lab instead deletes all resources it created, even after an error, and verifies cleanup.

## Live results: October 20, 2026

| Region | Test | Outcome |
|---|---|---|
| South Africa North | Two `D2_v2` -> `D2ds_v5` resizes, with both target slots reserved before shutdown | Passed; HTTP downtime **102.01 s** and **116.99 s**; VM, disk, network, application identity and payload preserved |
| West Europe | Reserve two `D2ds_v5` slots, then create two target VMs against them | Passed; both VMs consumed the reservation and served healthy HTTP |

The full test fell back after West Europe rejected legacy creation with `SkuNotAvailable`. Its deallocate/resize/associate/start path is not a like-for-like timing comparison with the earlier direct resize.

Verified capacity holding intervals were approximately **7 min 12 s** and **6 min 14 s**, respectively. Both reservations were reduced to zero and deleted; release caused no observed HTTP failures or guest reboots. All three test resource groups were independently verified absent, with no tagged resources remaining, by **15:23 UTC**.

The [curated measurements](results/capacity-reservation-20261020/summary.json) retain counts and timings without environment identifiers. These are single-run observations, not future capacity guarantees.

## Executable lab

[Invoke-ReservedResizeLab.ps1](scripts/Invoke-ReservedResizeLab.ps1) creates regional, standalone Ubuntu 22.04 Gen1 VMs using the existing [template](infra/main.bicep) and [application](infra/cloud-init.yaml). It accepts no existing VM or resource-group names.

The target is fixed to `Standard_D2ds_v5`; supported source choices are `Standard_D1`, `Standard_D2_v2`, and `Standard_D2s_v3`. Other sizes or zonal migrations require a separate compatibility review and implementation.

The observer is a separate PowerShell 7 process on the Windows execution host, whose hosting infrastructure was not recorded. It probes each VM every second with an 800 ms timeout.

**This creates billable resources, deliberately interrupts the lab applications, and deletes all resource groups it creates, including after errors.**

```powershell
$configDir = 'C:\.AutenticazioneCLI\<environment>\.azure'
$env:AZURE_CONFIG_DIR = $configDir
az account show

.\scripts\Invoke-ReservedResizeLab.ps1 `
  -ConfigDir $configDir `
  -SubscriptionId '<subscription-id>' `
  -Quantity 2 `
  -Regions @('westeurope', 'southafricanorth') `
  -SourceSize Standard_D2_v2 `
  -BaselineSeconds 60 `
  -RecoverySeconds 60
```

`Quantity 2` means two source VMs and two simultaneously reserved target slots, resized sequentially. Capacity failures can trigger the next supplied region **only before any resize starts**, after failed-region cleanup. Other errors stop the run.

Use `-Regions @('westeurope')` to forbid fallback. Success elsewhere does not validate West Europe capacity.

### Partial test: West Europe target allocation

When legacy VM creation is unavailable, test the target independently: reserve its capacity first, then create new VMs explicitly against that reservation.

```powershell
.\scripts\Invoke-ReservedResizeLab.ps1 `
  -ConfigDir $configDir `
  -SubscriptionId '<subscription-id>' `
  -Quantity 2 `
  -Regions @('westeurope') `
  -TargetAllocationOnly
```

This mode verifies reserved allocation, HTTP health, and non-disruptive reservation release. It does **not** resize a legacy VM or measure resize downtime.

Raw command responses and probe logs stay in ignored `evidence/reserved-resize-<timestamp>-<suffix>/`. After a successful run:

```powershell
.\scripts\Analyze-Results.ps1 `
  -EvidencePath '.\evidence\reserved-resize-<timestamp>-<suffix>' `
  -ExpectedExperiments 2
```

The allocation-only mode uses `evidence/reserved-allocation-<timestamp>-<suffix>/` and writes allocation results rather than resize results. The original publication exporter does not support either new schema; curate public results separately.

## Local validation

```powershell
.\tests\Test-CapacityReservation.ps1
.\tests\Test-LabCommon.ps1
.\tests\Test-Monitor.ps1
.\tests\Test-Analysis.ps1
```

Mocked reservation tests cover failed gates, two-slot accounting, operation ordering, runtime allocation, error propagation, and non-disruptive release. Only live tests establish regional results.

## Sources

- [On-demand capacity reservation: terms, billing, support, and SLA](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview)
- [Associate an existing VM with reserved capacity](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-associate-vm)
- [Resize VMs associated with a capacity reservation group](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-modify)
- [Release a reservation without deallocating the VM](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-remove-vm#update-the-reserved-quantity-to-zero)
- [Resize behavior and compatibility constraints](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/resize-vm)
