# Azure VM in-place resize laboratory

A reproducible experiment measuring application downtime while modernizing legacy Azure VM sizes, using **Bicep**, **Azure CLI**, and an independent **PowerShell HTTP monitor**.

## Measured results

Two Linux VMs were created in **South Africa North** on **October 20, 2026**, after West Europe rejected both legacy sizes with `SkuNotAvailable`.

| Resize | Azure CLI command duration | Observed HTTP downtime |
|---|---:|---:|
| `Standard_D1` -> `Standard_D2ds_v5` | 40.90 s | **47.99 s** |
| `Standard_D2_v2` -> `Standard_D2ds_v5` | 38.15 s | **30.99 s** |

Both operations preserved the VM resource, OS disk, NIC, static public IP, application identity, and persistent payload. Both restarted the guest. **In-place does not mean zero downtime.**

All six resource groups created across the preliminary and measured runs were deleted and verified absent. No policy exemption was needed in the successful deployments.

**Read the [experiment report](REPORT.md)** for feasibility, application/storage continuity, observed downtime, and the procedure.

## Repository layout

| Path | Purpose |
|---|---|
| [REPORT.md](REPORT.md) | Detailed experiment and operational guidance |
| [infra/main.bicep](infra/main.bicep) | VM, disk, network, static public IP, and monitor-restricted NSG |
| [infra/cloud-init.yaml](infra/cloud-init.yaml) | nginx application, persistent payload, and per-boot health metadata |
| [infra/exemption.bicep](infra/exemption.bicep) | Conditional, expiring, lab-scoped policy waiver |
| [scripts/Invoke-Lab.ps1](scripts/Invoke-Lab.ps1) | Deployment, regional retries, monitoring, resize, verification, and cleanup |
| [scripts/Monitor-Http.ps1](scripts/Monitor-Http.ps1) | One HTTP probe per second, with JSONL evidence |
| [scripts/Analyze-Results.ps1](scripts/Analyze-Results.ps1) | Downtime windows, latency percentiles, and cleanup accounting |
| [scripts/Collect-LabMetrics.ps1](scripts/Collect-LabMetrics.ps1) | Optional CPU and I/O collection from Azure Monitor |
| [scripts/Export-PublicationEvidence.ps1](scripts/Export-PublicationEvidence.ps1) | Curated, sanitized export; raw evidence stays local |
| [results/resize-20261020-101252](results/resize-20261020-101252/) | Sanitized measured evidence, not synthetic test data |
| [tests](tests/) | Local monitor and analysis tests |

## Prerequisites

- **Windows and PowerShell 7**. The scripts use Windows process options; cross-platform execution is not claimed.
- Azure CLI, Bicep CLI (`az bicep install` if missing), and OpenSSH `ssh-keygen`.
- An authenticated Azure CLI cache outside the repository.
- An explicitly selected subscription with resource creation/deletion permissions, sufficient quota, and allocatable source/target sizes.
- A stable public IPv4 address for the external monitor.
- Policy exemption permissions only if a blocking public-exposure policy actually requires a waiver.

## Validate without deploying

```powershell
$env:AZURE_CONFIG_DIR = 'C:\.AutenticazioneCLI\<environment>\.azure'
az bicep build --file .\infra\main.bicep --stdout | Out-Null
az bicep build --file .\infra\exemption.bicep --stdout | Out-Null
.\tests\Test-Monitor.ps1
.\tests\Test-Analysis.ps1
```

Recompute the published measurements without Azure access:

```powershell
.\scripts\Analyze-Results.ps1 -EvidencePath '.\results\resize-20261020-101252'
```

## Run a new experiment

**This creates billable resources, interrupts the test applications, and deletes the resource groups it creates, including after errors. Do not use it against production VMs.**

```powershell
$configDir = 'C:\.AutenticazioneCLI\<environment>\.azure'
$env:AZURE_CONFIG_DIR = $configDir
az account show

.\scripts\Invoke-Lab.ps1 `
  -ConfigDir $configDir `
  -SubscriptionId '<subscription-id>' `
  -Regions @('westeurope', 'southafricanorth', 'francecentral', 'uksouth') `
  -BaselineSeconds 60 `
  -RecoverySeconds 60
```

The script refuses to proceed if the active subscription differs from the explicit parameter. Region retries do not guarantee capacity. The lab tests D1 and D2_v2 against D2ds_v5; changing the families requires a new compatibility review.

While the experiment is running, optional platform metrics can be collected in a second PowerShell session:

```powershell
.\scripts\Collect-LabMetrics.ps1 `
  -ConfigDir 'C:\.AutenticazioneCLI\<environment>\.azure' `
  -EvidencePath '.\evidence\resize-<UTC-timestamp>'
```

After completion:

```powershell
.\scripts\Analyze-Results.ps1 -EvidencePath '.\evidence\resize-<UTC-timestamp>'
```

## Evidence and publication

Raw command outputs, account details, tenant governance configuration, authentication cache paths, deployment parameters, and Activity Logs are **not committed**. The local `evidence/` and `.azure/` directories are ignored.

The checked-in [results](results/resize-20261020-101252/) contain sanitized measurements with timestamps, durations, probe outcomes, hashes, and identity equality preserved. Environment identifiers are replaced with deterministic labels and public addresses with documentation-only IPv4 addresses. See the [publication manifest](results/resize-20261020-101252/publication-manifest.json).

To prepare a new measured run for publication, use an unused output directory, review the exported files, and commit only the intended export:

```powershell
.\scripts\Export-PublicationEvidence.ps1 `
  -EvidencePath '.\evidence\resize-<UTC-timestamp>' `
  -OutputPath '.\results\resize-<UTC-timestamp>'
```

The exporter is deliberately limited to the expected two-experiment lab schema. It is not a general-purpose guarantee that arbitrary Azure output is safe to publish.

## Scope and limitations

- The application is a low-load nginx health endpoint, not a transactional workload or performance benchmark.
- The monitor uses a 1 s interval and 800 ms timeout; downtime is sampled client-observed unavailability.
- Each source size was resized once. Results are observations, not Azure guarantees.
- The direct resize path was exercised; explicit deallocation and real policy exemption paths were not.
- Plain HTTP is restricted to the monitor's IPv4/32 and used only for a temporary, non-sensitive lab.
