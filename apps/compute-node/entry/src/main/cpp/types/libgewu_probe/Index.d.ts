export const start: (modelPath: string, request: string, logPath: string, waitSeconds: number, sessionKey?: string) => number;
export const takeEvents: () => string[];
export const complete: (jobId?: number) => void;
export const cancel: (jobId?: number) => void;
export const closeSession: (sessionKey: string) => void;
