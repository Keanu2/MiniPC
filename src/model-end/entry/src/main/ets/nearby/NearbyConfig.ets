// Build the model-phone and chat-phone HAPs from this single role setting.
export const IS_SERVER: boolean = true;
export const USE_LINK_ENHANCE: boolean = true;
export const COMPUTE_MANUFACTURE_ID: number = 0x6E77;
export const COMPUTE_ADV_TYPE: number = 1;
/** Advertised fingerprint length in bytes. Random BLE addresses change between
 *  reconnects, so identity has to come from the payload instead. */
export const COMPUTE_ADV_KEY_BYTES: number = 4;
