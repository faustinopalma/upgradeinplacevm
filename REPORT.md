# In-place Azure VM resize: application continuity and measured downtime

## Motivation and objective

Retirement plans for legacy Azure VM families and announced price changes create a practical modernization question: **can an existing application move to a newer VM size without rebuilding the VM, reinstalling the application, or moving its persistent data?**

An alternative is to deploy a replacement VM, copy or restore data, reinstall dependencies, and switch traffic. That may be appropriate, but it introduces a migration workflow. This experiment instead tests the narrower **in-place resize** option: change the hardware size while retaining the existing Azure VM resource and its storage.

The objective is to establish:

1. **Feasibility:** can one original D-series VM and one Dv2 VM reach a compatible modern size?
2. **Continuity:** do the installed application, persistent payload, VM identity, disk, and network configuration survive?
3. **Service impact:** how long does an external client lose application access, and how does that compare with the duration reported by the resize command?

Here, *update* means **VM-size modernization**, not an operating-system upgrade, a Gen1-to-Gen2 conversion, or a change of disk controller. *In-place* describes preservation of the existing resource and data; it does not imply that the guest remains running.

## Test design

| Experiment | Source | Target |
|---|---|---|
| Legacy v1 | `Standard_D1`: 1 vCPU, 3.5 GiB RAM | `Standard_D2ds_v5`: 2 vCPUs, 8 GiB RAM |
| Legacy v2 | `Standard_D2_v2`: 2 vCPUs, 7 GiB RAM | `Standard_D2ds_v5`: 2 vCPUs, 8 GiB RAM |

`D2ds_v5` is among the destinations in [Microsoft's modernization guide](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide). It supports the sources' Gen1/SCSI configuration and includes local temporary storage. This keeps the test focused on resizing rather than combining it with a generation or storage-controller conversion. It is not a universal right-sizing recommendation: the D1 case also increases CPU and memory.

Each VM ran Ubuntu 22.04 with the same nginx application. The HTTP health response included a persistent application identity, payload hash, OS identity, boot ID, and boot counter. These fields distinguish recovery of the original application from merely receiving a response from a newly installed service.

```text
Independent external monitor
    | HTTP /health every second
    v
Static public IP -> NSG allowing only monitor IPv4/32:8080
    |
Existing VM -> installed nginx application
    |
Existing managed OS disk -> persistent identity and payload
```

The monitor ran outside the VM being resized, so guest restart could not interrupt the observer. Separate resource groups isolated the two experiments and allowed complete cleanup.

## Results

**Both legacy VMs were resized successfully without rebuilding the application or replacing persistent storage.** The VM, OS disk, NIC, static public IP, application identity, and payload were preserved. Both guests restarted: *in-place* did not mean zero downtime.

The experiment ran on **October 20, 2026**, in **South Africa North**. Real deployment attempts in West Europe rejected both source sizes with `SkuNotAvailable`; the next region supported both source VMs and the target. This is evidence for the tested subscription and time, not a claim of universal regional availability.

| Measurement | D1 -> D2ds_v5 | D2_v2 -> D2ds_v5 |
|---|---:|---:|
| Resize command duration | 40.90 s | 38.15 s |
| **Observed HTTP downtime** | **47.99 s** | **30.99 s** |
| Last-good to first-good probe interval | 49.00 s | 32.00 s |
| Failed / total probes | 48 / 189 | 31 / 172 |
| Monitoring duration | 188.11 s | 171.09 s |
| Successful baseline probes | 65 | 65 |
| Successful probes after command completion | 68 | 69 |
| Explicit deallocation required | No | No |

The target appeared in each running VM's resize options, so both used direct `az vm resize`. The explicit deallocate/resize/start path was **not tested**.

## What was preserved

Ubuntu 22.04 Gen1 ran nginx with an HTTP `/health` endpoint. A systemd service regenerated boot metadata; a small payload and application identity were stored on the **managed OS disk**, not temporary storage.

| Verification after resize | Both experiments |
|---|---|
| Azure VM resource ID and `vmId` | Unchanged |
| Managed OS disk, NIC, and static public IP | Unchanged |
| Application identity and guest `machine-id` | Unchanged |
| Persistent payload SHA-256 | Unchanged, including all successful health probes |
| Guest `boot_id` and application boot counter | New boot ID; counter increased from 1 to 2 |
| Application | HTTP health recovered without reinstallation |
| OS disk | Same 30 GiB Standard LRS disk, Hyper-V generation V1 |

This demonstrates persistent OS-disk and application continuity for this workload. It does **not** establish temporary-disk persistence, separate data-disk continuity, database consistency, or preservation of in-memory sessions.

## Downtime measurement

An independent PowerShell process outside the tested VMs requested `/health` **every second**, with an **800 ms timeout** and no retries. It recorded request start/end, latency, status/error, and health payload in JSONL.

**Observed downtime** is the interval from the start of the first failed probe to the start of the first subsequent successful probe. All 79 failed requests timed out without an HTTP response code.

| UTC event | D1 -> D2ds_v5 | D2_v2 -> D2ds_v5 |
|---|---|---|
| Resize launched | 10:16:59.283 | 10:23:48.624 |
| Last successful probe before interruption | 10:17:07.087 | 10:23:54.209 |
| First failed probe | 10:17:08.099 | 10:23:55.214 |
| Resize procedure returned | 10:17:40.229 | 10:24:26.813 |
| Last failed probe | 10:17:55.086 | 10:24:25.210 |
| First recovered probe | 10:17:56.085 | 10:24:26.208 |

For D1, HTTP recovery was observed **15.86 s after** command completion. For D2_v2, the recovered probe started **0.61 s before** the command returned. **Control-plane success is not application readiness.**

Maximum actual probe spacing was 1.040 s and 1.024 s, respectively. These are sampled client observations, not exact hypervisor stop/start times. Each source was tested once; the results are not Azure guarantees.

| Successful-request latency | D1 baseline / after | D2_v2 baseline / after |
|---|---:|---:|
| p50 | 176.91 / 181.18 ms | 174.79 / 175.40 ms |
| p95 | 225.27 / 200.23 ms | 196.88 / 185.15 ms |
| p99 | 441.66 / 369.42 ms | 450.23 / 197.34 ms |

Post-resize percentiles use successful requests after command completion. Latency includes the external network path. One request per second is not a throughput benchmark.

## Procedure

1. Deploy each source VM using [main.bicep](infra/main.bicep) and [cloud-init.yaml](infra/cloud-init.yaml). Permit TCP 8080 only from the monitor's public IPv4/32; do not open SSH/RDP ingress.
2. Wait for valid HTTP health, then capture VM/disk/network identities, application identity, and payload hash.
3. Check `az vm list-vm-resize-options`. Start the external monitor and record at least 60 s of healthy baseline.
4. Resize to `Standard_D2ds_v5`, keeping the monitor active.
5. Observe HTTP recovery and at least 60 additional seconds; compare identities/hash and confirm the target size and new boot ID.
6. Save results, stop monitoring, and delete the temporary resource groups.

The automation captures the Azure identities and application state before resizing, then verifies them after recovery. A successful command alone is insufficient: the test fails if the target size is not applied, persistent identifiers or payload hashes differ, or the expected reboot is not observed.

For an existing VM, the central operations are:

```powershell
az vm list-vm-resize-options --resource-group <group> --name <vm> -o table
az vm resize --resource-group <group> --name <vm> --size Standard_D2ds_v5
```

If the compatible target is not available on the current allocation, a deallocate/resize/start sequence may be necessary. That can extend the outage and requires checking regional capacity; its duration cannot be inferred from these direct-resize results. See [Microsoft's resize guidance](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/resize-vm).

The complete Windows/PowerShell 7 automation is [Invoke-Lab.ps1](scripts/Invoke-Lab.ps1):

```powershell
.\scripts\Invoke-Lab.ps1 `
  -ConfigDir 'C:\.AutenticazioneCLI\<environment>\.azure' `
  -SubscriptionId '<subscription-id>' `
  -Regions @('westeurope', 'southafricanorth') `
  -BaselineSeconds 60 -RecoverySeconds 60
```

**This creates billable resources and deletes the groups it creates, including after errors.** It is a disposable lab, not a production change script. Existing workloads require backup/restore verification, a maintenance window, and their own application/data consistency checks.

## What the result means operationally

The test supports using a compatible resize to preserve an installed application and its persistent OS-disk data. It does not establish behavior for a transactional workload: a database could need crash recovery, a service might start more slowly, and in-memory state would be lost on reboot.

For production, validate backups and recovery, storage/controller compatibility, dependencies, and application-specific consistency. Plan a maintenance window; resizing back is not a guaranteed rollback because legacy capacity may be unavailable. If the VM is retained, update the desired `vmSize` in its IaC to avoid a later deployment reversing the change.

To mitigate target allocation failure, [reserve capacity before stopping the source](CAPACITY-RESERVATION.md). The companion lab exercises that workflow separately; the original measurements above used direct resize without a capacity reservation.

Avoiding user-visible downtime requires additional instances and controlled traffic switching, not just a different resize command. This experiment deliberately measures the interruption of a single instance.

## Evidence and cleanup

[Published measurements](results/resize-20261020-101252/) include all HTTP probes, before/after results, guest diagnostics, disk metadata, and a [computed summary](results/resize-20261020-101252/summary.json). Identifiers/IPs are pseudonymized; timing, outcomes, hashes, and equality checks are preserved. Raw account responses and credentials are excluded. The original result's `hyperVGeneration` field contains an image SKU; separate disk metadata confirms actual `V1`.

Recompute downtime and percentiles without Azure access:

```powershell
.\scripts\Analyze-Results.ps1 -EvidencePath '.\results\resize-20261020-101252'
```

All **six resource groups** across the preliminary and measured runs were deleted. The [independent final check](results/resize-20261020-101252/cleanup-final-verification.json) found no remaining groups or tagged resources at **10:33:50 UTC**. Temporary keys and monitoring processes were removed.

**Conclusion:** direct in-place resize preserved this application's installation and persistent OS-disk data, but caused approximately **48 s and 31 s of client-observed downtime**. A single-VM resize is not a zero-downtime availability strategy.
