type DeviceCodeStartResponse = {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete?: string;
  expires_in: number;
  interval?: number;
};

type TokenSuccessResponse = {
  access_token: string;
  token_type: string;
  scope: string;
};

type TokenErrorResponse = {
  error: string;
  error_description?: string;
};

export type DevicePollResult =
  | { status: "pending"; retryInSeconds: number }
  | { status: "slow_down"; retryInSeconds: number }
  | { status: "declined"; message: string }
  | { status: "expired"; message: string }
  | { status: "error"; message: string }
  | {
      status: "authorized";
      accessToken: string;
      tokenType: string;
      scope: string;
    };

export class DeviceAuthService {
  private readonly clientId: string;
  private readonly issuedTokens = new Map<string, Date>();

  constructor(options: { clientId: string }) {
    this.clientId = options.clientId;
  }

  async startDeviceFlow(): Promise<DeviceCodeStartResponse> {
    const body = new URLSearchParams({
      client_id: this.clientId,
      scope: "read:user",
    });

    const response = await fetch("https://github.com/login/device/code", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body,
    });

    if (!response.ok) {
      throw new Error(`Device sign start failed with status ${response.status}`);
    }

    const payload = (await response.json()) as DeviceCodeStartResponse;

    if (!payload.device_code || !payload.user_code || !payload.verification_uri) {
      throw new Error("Device sign response missing required fields");
    }

    return payload;
  }

  async pollForToken(deviceCode: string): Promise<DevicePollResult> {
    const body = new URLSearchParams({
      client_id: this.clientId,
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    });

    const response = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body,
    });

    if (!response.ok) {
      return {
        status: "error",
        message: `Token poll failed with status ${response.status}`,
      };
    }

    const payload = (await response.json()) as TokenSuccessResponse | TokenErrorResponse;

    if ("access_token" in payload) {
      this.registerAccessToken(payload.access_token);
      return {
        status: "authorized",
        accessToken: payload.access_token,
        tokenType: payload.token_type,
        scope: payload.scope,
      };
    }

    if (payload.error === "authorization_pending") {
      return { status: "pending", retryInSeconds: 5 };
    }

    if (payload.error === "slow_down") {
      return { status: "slow_down", retryInSeconds: 10 };
    }

    if (payload.error === "expired_token") {
      return { status: "expired", message: "Device code expired. Start again." };
    }

    if (payload.error === "access_denied") {
      return { status: "declined", message: "Device sign was denied by the user." };
    }

    return {
      status: "error",
      message: payload.error_description ?? payload.error ?? "Unknown token polling error",
    };
  }

  registerAccessToken(token: string): void {
    this.issuedTokens.set(token, new Date());
  }

  hasAccessToken(token: string): boolean {
    return this.issuedTokens.has(token);
  }
}
