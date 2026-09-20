import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const MAX_EDGE: number = 720;

export function pickJpegDataUrl(): Promise<string> {
  const picker = new photoAccessHelper.PhotoViewPicker();
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = 1;
  return picker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
    if (result.photoUris.length === 0) {
      return Promise.resolve('');
    }
    return encodeJpegDataUrl(result.photoUris[0]);
  }).catch((error: BusinessError) => {
    if (isCancel(error)) {
      return '';
    }
    hilog.error(0, 'ImageAttach', 'select failed code=%{public}d msg=%{public}s', error.code, error.message);
    return Promise.reject(error);
  });
}

function isCancel(error: BusinessError): boolean {
  if (error.code === 13900020 || error.code === 13900002 || error.code === 801) {
    return true;
  }
  const msg = error.message ? error.message.toLowerCase() : '';
  return msg.indexOf('cancel') >= 0;
}

async function encodeJpegDataUrl(uri: string): Promise<string> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const source = image.createImageSource(file.fd);
    try {
      const info = await source.getImageInfo();
      let width = info.size.width;
      let height = info.size.height;
      if (width < 1 || height < 1) {
        throw new Error('invalid image');
      }
      if (width > MAX_EDGE || height > MAX_EDGE) {
        const scale = Math.min(MAX_EDGE / width, MAX_EDGE / height);
        width = Math.max(1, Math.round(width * scale));
        height = Math.max(1, Math.round(height * scale));
      }
      const decoding: image.DecodingOptions = { desiredSize: { width: width, height: height } };
      const pixelMap = await source.createPixelMap(decoding);
      try {
        const packer = image.createImagePacker();
        try {
          const packed = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 70 });
          return 'data:image/jpeg;base64,' + new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
        } finally {
          await packer.release();
        }
      } finally {
        await pixelMap.release();
      }
    } finally {
      await source.release();
    }
  } finally {
    await fileIo.close(file);
  }
}
