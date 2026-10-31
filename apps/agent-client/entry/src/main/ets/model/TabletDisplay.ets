/** Default window footprint only. Content layout always follows the actual window. */
export const TABLET_WIDTH_MM = 127;
export const TABLET_HEIGHT_MM = 198;
export const REFERENCE_SCREEN_WIDTH_PX = 3120;
export const REFERENCE_SCREEN_HEIGHT_PX = 2080;
export const REFERENCE_SCREEN_DIAGONAL_INCHES = 14.2;
const MM_PER_INCH = 25.4;

export interface TabletPixels { width: number; height: number; }
export function physicalPixelsPerInch(width: number = REFERENCE_SCREEN_WIDTH_PX,
  height: number = REFERENCE_SCREEN_HEIGHT_PX, diagonal: number = REFERENCE_SCREEN_DIAGONAL_INCHES): number {
  if (!Number.isFinite(width) || width <= 0 || !Number.isFinite(height) || height <= 0 ||
    !Number.isFinite(diagonal) || diagonal <= 0) {
    return Math.sqrt(REFERENCE_SCREEN_WIDTH_PX * REFERENCE_SCREEN_WIDTH_PX +
      REFERENCE_SCREEN_HEIGHT_PX * REFERENCE_SCREEN_HEIGHT_PX) / REFERENCE_SCREEN_DIAGONAL_INCHES;
  }
  return Math.sqrt(width * width + height * height) / diagonal;
}
export function tabletSizePx(screenWidth: number = REFERENCE_SCREEN_WIDTH_PX,
  screenHeight: number = REFERENCE_SCREEN_HEIGHT_PX): TabletPixels {
  const ppi = physicalPixelsPerInch(screenWidth, screenHeight);
  return { width: Math.round(TABLET_WIDTH_MM / MM_PER_INCH * ppi),
    height: Math.round(TABLET_HEIGHT_MM / MM_PER_INCH * ppi) };
}
/** Clamp the initial OUTER window to the usable desktop; no fixed aspect or size limits. */
export function fitDefaultWindow(desired: TabletPixels, availableWidth: number, availableHeight: number): TabletPixels {
  return {
    width: Math.min(desired.width, Number.isFinite(availableWidth) && availableWidth > 0 ? Math.floor(availableWidth) : desired.width),
    height: Math.min(desired.height, Number.isFinite(availableHeight) && availableHeight > 0 ? Math.floor(availableHeight) : desired.height)
  };
}
