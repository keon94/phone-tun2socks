using System;
using System.Diagnostics.Eventing.Reader;

public static class WlanTunnelSignal {
    private static EventLogWatcher watcher;

    public static string TargetSSID = "";
    public static volatile bool Connected = false;
    public static volatile bool Changed = false;

    public static void Start() {
        var query = new EventLogQuery(
            "Microsoft-Windows-WLAN-AutoConfig/Operational",
            PathType.LogName,
            "*[System[(EventID=8001 or EventID=8003)]]"
        );

        watcher = new EventLogWatcher(query);
        watcher.EventRecordWritten += (sender, e) => {
            if (e.EventException != null) {
                System.Console.WriteLine("WLAN watcher error: " + e.EventException.Message);
                return;
            }

            if (e.EventRecord == null) return;

            using (var record = e.EventRecord) {
                string message = record.FormatDescription();
                bool isTarget = false;

                foreach (string line in message.Split(
                    new[] { '\r', '\n' },
                    StringSplitOptions.RemoveEmptyEntries
                )) {
                    int marker = line.IndexOf("SSID:", StringComparison.OrdinalIgnoreCase);
                    if (marker >= 0 &&
                        line.Substring(marker + 5).Trim().Equals(
                            TargetSSID, StringComparison.OrdinalIgnoreCase
                        )) {
                        isTarget = true;
                        break;
                    }
                }

                System.Console.WriteLine(
                    "WLAN event " + record.Id +
                    (isTarget ? " for target SSID" : " for another SSID")
                );

                if (isTarget && record.Id == 8001) {
                    Connected = true;
                    Changed = true;
                } else if (isTarget && record.Id == 8003) {
                    Connected = false;
                    Changed = true;
                }
            }
        };

        watcher.Enabled = true;
    }

    public static void Stop() {
        if (watcher != null) {
            watcher.Enabled = false;
            watcher.Dispose();
            watcher = null;
        }
    }
}