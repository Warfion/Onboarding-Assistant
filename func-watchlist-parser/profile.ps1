# Azure Functions profile file.
# Runs once when the Function App cold-starts.

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
}
