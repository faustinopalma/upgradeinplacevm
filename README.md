# Azure VM in-place resize laboratory

Can a legacy Azure VM move to a modern size without rebuilding its application or moving persistent data? This laboratory tests **feasibility, application continuity, and client-observed downtime**, then adds capacity reservation to mitigate allocation failure after deallocation.

The experiments use **Bicep**, **Azure CLI**, Ubuntu 22.04, and a **PowerShell HTTP observer**. Here, *in-place* means retaining the existing VM resource and disks, not upgrading the OS or keeping the guest continuously available.

- [Results](#results)
- [Test design and measurement](#test-design-and-measurement)
- [Capacity-reserved resize methodology](#capacity-reserved-resize-methodology)
- [Run the laboratory](#run-the-laboratory)
- [Evidence and cleanup](#evidence-and-cleanup)
- [Repository layout](#repository-layout)
- [Limitations and production use](#limitations-and-production-use)

## Results

All tests below ran on **October 20, 2026**.

| Region | Procedure | Source -> target | Control-plane duration | Observed HTTP downtime |
|---|---|---|---:|---:|
| South Africa North | Direct resize | `D1` -> `D2ds_v5` | 40.90 s | **47.99 s** |
| South Africa North | Direct resize | `D2_v2` -> `D2ds_v5` | 38.15 s | **30.99 s** |
| South Africa North | Capacity-reserved resize, VM 1 | `D2_v2` -> `D2ds_v5` | 102.23 s | **102.01 s** |
| South Africa North | Capacity-reserved resize, VM 2 | `D2_v2` -> `D2ds_v5` | 117.55 s | **116.99 s** |
| West Europe | Reserve two slots, then create two target VMs | New `D2ds_v5` VMs | Not a resize | Not applicable |

The four resizes preserved the VM resource, managed OS disk, NIC, static public IP, application identity, and persistent payload. Each guest rebooted; the boot counter increased from 1 to 2. **In-place does not mean zero downtime.**

Direct resize used `az vm resize` without explicit deallocation. The reserved path deliberately used **deallocate -> resize -> associate -> start**, with both target slots secured before the first shutdown. Its duration includes that sequence and is not a like-for-like benchmark of reservation overhead.

West Europe rejected legacy creation with `SkuNotAvailable`, so the complete resize tests used South Africa North. The subsequent **West Europe partial test succeeded**: two target slots were reserved first, then two VMs were created against them and verified in the reservation's runtime allocation. This validates target allocation, **not a legacy resize in West Europe**.

The reservations were held for approximately **7 min 12 s** and **6 min 14 s**, respectively, from successful capacity verification to quantity-zero verification. Both were then deleted. Release caused no observed HTTP failures or guest reboots.

## Test design and measurement

### Workload and compatibility

| Size | vCPUs | Memory |
|---|---:|---:|
| `Standard_D1` | 1 | 3.5 GiB |
| `Standard_D2_v2` | 2 | 7 GiB |
| `Standard_D2ds_v5` | 2 | 8 GiB |

`D2ds_v5` is a destination in [Microsoft's modernization guide](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide). It supports the sources' Gen1/SCSI configuration and includes local temporary storage. This isolates resizing from generation or controller conversion; it is not a universal right-sizing recommendation.

Each VM ran nginx with an HTTP `/health` endpoint. Application identity and a small payload lived on the **30 GiB Standard LRS managed OS disk**, not temporary storage. A systemd service regenerated boot metadata on startup.

| Continuity check | Expected after resize |
|---|---|
| VM resource ID and `vmId`, OS disk ID, NIC ID, static public IP | Unchanged |
| Application identity, guest `machine-id`, payload SHA-256 | Unchanged |
| Guest `boot_id` and boot counter | New boot ID; increased counter |
| Application | Healthy without reinstallation |

### Observer

```text
Windows execution host: separate PowerShell observer process
    | HTTP /health every second
    v
Static public IP -> NSG permitting only observer IPv4/32:8080
    |
Ubuntu VM -> nginx -> persistent identity and payload on managed OS disk
```

The observer ran outside the tested VMs, on the Windows host executing the lab. Its hardware, hosting infrastructure, and geographic location were not recorded. Guest restarts therefore did not stop the observer, but latency includes its network path to Azure.

Each probe used an **800 ms timeout**, no retries, and recorded UTC timestamps, latency, status/error, and health payload in JSONL. **Observed downtime** runs from the start of the first failed probe to the start of the first subsequent successful probe. It is a sampled client observation, not an exact hypervisor stop/start interval.

<details>
<summary>Direct-resize probe details and latency</summary>

| Measurement | D1 -> D2ds_v5 | D2_v2 -> D2ds_v5 |
|---|---:|---:|
| Last-good to first-good probe interval | 49.00 s | 32.00 s |
| Failed / total probes | 48 / 189 | 31 / 172 |
| Monitoring duration | 188.11 s | 171.09 s |
| Successful baseline probes | 65 | 65 |
| Successful probes after command completion | 68 | 69 |
| Maximum actual probe spacing | 1.040 s | 1.024 s |

All 79 failed probes timed out without an HTTP response code.

| UTC event | D1 -> D2ds_v5 | D2_v2 -> D2ds_v5 |
|---|---|---|
| Resize launched | 10:16:59.283 | 10:23:48.624 |
| Last successful probe before interruption | 10:17:07.087 | 10:23:54.209 |
| First failed probe | 10:17:08.099 | 10:23:55.214 |
| Resize procedure returned | 10:17:40.229 | 10:24:26.813 |
| Last failed probe | 10:17:55.086 | 10:24:25.210 |
| First recovered probe | 10:17:56.085 | 10:24:26.208 |

For D1, recovery was observed **15.86 s after** command completion; for D2_v2, the recovered probe started **0.61 s before** it returned. Control-plane success is not application readiness.

| Successful-request latency | D1 baseline / after | D2_v2 baseline / after |
|---|---:|---:|
| p50 | 176.91 / 181.18 ms | 174.79 / 175.40 ms |
| p95 | 225.27 / 200.23 ms | 196.88 / 185.15 ms |
| p99 | 441.66 / 369.42 ms | 450.23 / 197.34 ms |

Post-resize percentiles use successful requests after command completion. One request per second is not a throughput benchmark.

</details>

## Capacity-reserved resize methodology

Deallocation releases the current compute allocation. Neither the target size nor a return to the legacy size is then assured. **Quota and SKU listings do not reserve hardware**, nor does a Reserved Instance, which provides a billing discount. An **On-demand Capacity Reservation** protects compute capacity under an SLA, not guest or application recovery.

1. **Preflight:** verify backups and restore, OS/disk compatibility, target size, region/zone, and quota for running sources plus reserved targets. Check placement support; Availability Sets, for example, are unsupported.
2. **Capture the baseline:** keep sources running and record the Azure and application identities listed above.
3. **Reserve the whole batch:** require `Succeeded`, matching size/placement, and enough free slots in both configured and runtime capacity. Start external monitoring and require a healthy baseline.
4. **Gate and resize each VM:** recheck remaining slots, then deallocate, resize while deallocated, explicitly associate with the reservation group, verify that association, and start. A failed gate means **no source shutdown**; never fall back to an unreserved start.
5. **Accept recovery:** confirm `virtualMachinesAllocated` contains the VM, verify application health and persistent identities/hash, and confirm the expected reboot.
6. **Release after acceptance:** with monitoring active, set reserved quantity to zero, remove VM associations, and delete the reservation and its group. Verify application continuity and unchanged boot IDs; no second deallocation is needed.

For production, a failed resize or application check calls for retaining useful reserved capacity and investigating. The disposable lab instead deletes all resources it created, even after an error.

### Duration and cost

On-demand reservations have **no minimum term commitment** and can be deleted after the test. The script does not request scheduled Future or Block reservations.

Unused reserved slots are billable. While sources run and target slots are unused, both incur charges; a VM consuming its reserved slot does not incur a second compute charge for that slot. Disks and networking are billed separately. Measured holding time is not a final invoice or billing-granularity guarantee.

## Run the laboratory

### Prerequisites and local validation

- **Windows and PowerShell 7**; cross-platform execution is not claimed.
- Azure CLI, Bicep CLI (`az bicep install` if missing), and OpenSSH `ssh-keygen`.
- An authenticated Azure CLI cache outside the repository.
- An explicitly selected subscription with creation/deletion permissions, sufficient quota, and allocatable sizes; reservation permissions for reserved tests.
- A stable public IPv4 address for the observer.

```powershell
$configDir = 'C:\.AutenticazioneCLI\<environment>\.azure'
$env:AZURE_CONFIG_DIR = $configDir
az account show

az bicep build --file .\infra\main.bicep --stdout | Out-Null
.\tests\Test-Monitor.ps1
.\tests\Test-Analysis.ps1
.\tests\Test-CapacityReservation.ps1
.\tests\Test-LabCommon.ps1
```

Mocked reservation tests cover failed gates, slot accounting, operation ordering, runtime allocation, error propagation, and non-disruptive release. They do not establish regional capacity.

**The following commands create billable resources, interrupt the lab applications, and delete all resource groups they create, including after errors. These are disposable experiments, not production change scripts.**

### Direct resize

[Invoke-Lab.ps1](scripts/Invoke-Lab.ps1) tests one `D1` and one `D2_v2` against `D2ds_v5`. It captures the baseline, checks `az vm list-vm-resize-options`, monitors through resize and recovery, and verifies continuity before cleanup. If the target is absent from resize options, it uses deallocate/resize/start; that branch was not needed in the direct-resize measurements above.

```powershell
.\scripts\Invoke-Lab.ps1 `
  -ConfigDir $configDir `
  -SubscriptionId '<subscription-id>' `
  -Regions @('westeurope', 'southafricanorth') `
  -BaselineSeconds 60 `
  -RecoverySeconds 60
```

### Capacity-reserved resize

[Invoke-ReservedResizeLab.ps1](scripts/Invoke-ReservedResizeLab.ps1) creates regional, standalone VMs. The target is fixed to `D2ds_v5`; source choices are `D1`, `D2_v2`, and `D2s_v3` with their `Standard_` prefix. Other sizes or zonal migrations require a separate compatibility review and implementation.

```powershell
.\scripts\Invoke-ReservedResizeLab.ps1 `
  -ConfigDir $configDir `
  -SubscriptionId '<subscription-id>' `
  -Quantity 2 `
  -Regions @('westeurope', 'southafricanorth') `
  -SourceSize Standard_D2_v2 `
  -BaselineSeconds 60 `
  -RecoverySeconds 60
```

`Quantity 2` means two running source VMs and two simultaneously reserved target slots, resized sequentially. Capacity failures can trigger the next supplied region **only before any resize starts**, after failed-region cleanup. Other errors stop the run. Use `-Regions @('westeurope')` to forbid fallback.

### West Europe target-only allocation

When legacy creation is unavailable, reserve target capacity first, then create new VMs explicitly against it:

```powershell
.\scripts\Invoke-ReservedResizeLab.ps1 `
  -ConfigDir $configDir `
  -SubscriptionId '<subscription-id>' `
  -Quantity 2 `
  -Regions @('westeurope') `
  -TargetAllocationOnly
```

This mode verifies reserved allocation, HTTP health, and reservation release, without a legacy source or resize downtime measurement.

### Analysis and optional metrics

Recompute the published direct-resize measurements without Azure access:

```powershell
.\scripts\Analyze-Results.ps1 -EvidencePath '.\results\resize-20261020-101252'
```

For new runs, use `evidence/resize-<UTC-timestamp>/` or `evidence/reserved-resize-<timestamp>-<suffix>/`. Pass `-ExpectedExperiments <quantity>` if the reserved batch differs from the default of two. Target-only runs write allocation records under `evidence/reserved-allocation-<timestamp>-<suffix>/`, not resize records for this analyzer.

Optional platform CPU and I/O metrics can be collected during a direct-resize run in another PowerShell session:

```powershell
.\scripts\Collect-LabMetrics.ps1 `
  -ConfigDir $configDir `
  -EvidencePath '.\evidence\resize-<UTC-timestamp>'
```

## Evidence and cleanup

- [Direct-resize evidence](results/resize-20261020-101252/): probes, before/after identities, guest diagnostics, disk metadata, and [computed summary](results/resize-20261020-101252/summary.json). UUIDs and IPs are pseudonymized while timestamps, hashes, outcomes, and identity equality are preserved; see the [publication manifest](results/resize-20261020-101252/publication-manifest.json). The original `hyperVGeneration` result field contains an image SKU; separate disk metadata confirms actual `V1`.
- [Reservation test summary](results/capacity-reservation-20261020/summary.json): curated counts, timings, allocation verification, and release outcomes, without environment identifiers.
- **Cleanup:** six resource groups from the original runs were verified absent at [10:33:50 UTC](results/resize-20261020-101252/cleanup-final-verification.json). All three groups from the reserved-resize and West Europe target-only tests were independently verified absent, with no tagged resources remaining, by **15:23 UTC**. Temporary SSH keys and observers were removed.

Raw evidence and local authentication state remain in ignored `evidence/` and `.azure/` directories. To export a new **original-schema direct-resize run**, use an unused output directory and review it before committing:

```powershell
.\scripts\Export-PublicationEvidence.ps1 `
  -EvidencePath '.\evidence\resize-<UTC-timestamp>' `
  -OutputPath '.\results\resize-<UTC-timestamp>'
```

This exporter does not support the reserved-resize or target-only schemas and is not a general-purpose sanitization guarantee; curate those results separately.

## Repository layout

| Path | Purpose |
|---|---|
| [infra/main.bicep](infra/main.bicep), [cloud-init.yaml](infra/cloud-init.yaml) | VM, disk, restricted network, and persistent nginx application |
| [Invoke-Lab.ps1](scripts/Invoke-Lab.ps1) | Original direct-resize experiments |
| [Invoke-ReservedResizeLab.ps1](scripts/Invoke-ReservedResizeLab.ps1) | Reserved resize and target-only allocation |
| [CapacityReservation.ps1](scripts/CapacityReservation.ps1), [Lab-Common.ps1](scripts/Lab-Common.ps1) | Capacity gates, association/release, shared CLI and health helpers |
| [Monitor-Http.ps1](scripts/Monitor-Http.ps1) | Independent HTTP observer |
| [Analyze-Results.ps1](scripts/Analyze-Results.ps1), [Collect-LabMetrics.ps1](scripts/Collect-LabMetrics.ps1) | Downtime analysis and optional platform metrics |
| [Export-PublicationEvidence.ps1](scripts/Export-PublicationEvidence.ps1) | Curated export for the original run schema |
| [results](results/), [tests](tests/) | Published evidence and local validation |

## Limitations and production use

- These are single-run, low-load nginx observations, not Azure downtime or future capacity guarantees.
- Persistent **OS-disk** continuity was tested, not temporary storage, separate data disks, database consistency, or in-memory state.
- Plain HTTP was restricted to the observer's IPv4/32 for a temporary, non-sensitive lab; no SSH/RDP ingress was opened.
- Production requires application-consistent backup/restore validation, compatible placement and storage, and a maintenance window. Returning to a legacy size is not a guaranteed rollback. Update the retained VM's desired size in IaC after acceptance.
- If prolonged interruption is unacceptable, prepare an already-running replacement with a data-consistent traffic-switching plan. Reserving compute alone does not make a single-VM resize highly available.

## References

- [Legacy VM modernization guide](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide)
- [Resize behavior and compatibility](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/resize-vm)
- [On-demand capacity reservation: terms, billing, support, and SLA](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-overview)
- [Associate an existing VM](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-associate-vm)
- [Resize within a reservation group](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-modify)
- [Release without deallocating the VM](https://learn.microsoft.com/en-us/azure/virtual-machines/capacity-reservation-remove-vm#update-the-reserved-quantity-to-zero)
