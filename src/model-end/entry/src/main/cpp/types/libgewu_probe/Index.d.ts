export const start: (modelPath: string, request: string, logPath: string) => number;
export const takeEvents: () => string[];
export const complete: (jobId?: number) => void;
export const cancel: (jobId?: number) => void;
