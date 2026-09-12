export const start: (modelPath: string, request: string, logPath: string) => boolean;
export const takeEvents: () => string[];
export const complete: () => void;
export const cancel: () => void;
