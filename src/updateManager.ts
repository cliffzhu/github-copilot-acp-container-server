export type UpdateSnapshot = {
  enabled: boolean;
  intervalSeconds: number;
  lastCheckedAt?: string;
  lastResult: "not_checked" | "up_to_date" | "update_available" | "error";
  message?: string;
};

export class UpdateManager {
  private readonly enabled: boolean;
  private readonly intervalSeconds: number;
  private lastCheckedAt?: Date;
  private lastResult: UpdateSnapshot["lastResult"] = "not_checked";
  private message?: string;

  constructor(options: { enabled: boolean; intervalSeconds: number }) {
    this.enabled = options.enabled;
    this.intervalSeconds = options.intervalSeconds;
  }

  snapshot(): UpdateSnapshot {
    return {
      enabled: this.enabled,
      intervalSeconds: this.intervalSeconds,
      lastCheckedAt: this.lastCheckedAt?.toISOString(),
      lastResult: this.lastResult,
      message: this.message,
    };
  }

  async checkForUpdates(currentVersion: string): Promise<UpdateSnapshot> {
    this.lastCheckedAt = new Date();

    if (!this.enabled) {
      this.lastResult = "up_to_date";
      this.message = "Auto-update is disabled.";
      return this.snapshot();
    }

    // v1 baseline: update detection is intentionally conservative until release-channel policy is finalized.
    this.lastResult = "up_to_date";
    this.message = `No update available for version ${currentVersion}.`;

    return this.snapshot();
  }
}
