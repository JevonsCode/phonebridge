import { decode } from 'jpeg-js';
import { z } from 'zod';

const positive = z.number().int().min(1).max(16384);
const screenshotSchema = z.object({
  mimeType: z.literal('image/jpeg'), data: z.string().min(4).max(2796204),
  width: positive.max(1280), height: positive.max(1280),
  screenWidth: positive, screenHeight: positive,
  cropLeft: z.number().int().min(0), cropTop: z.number().int().min(0),
  cropWidth: positive, cropHeight: positive,
}).strict();

export function validateScreenshot(value: unknown) {
  const result = screenshotSchema.parse(value);
  if (result.cropLeft + result.cropWidth > result.screenWidth || result.cropTop + result.cropHeight > result.screenHeight) throw new Error('Crop exceeds screen.');
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(result.data)) throw new Error('Invalid base64.');
  const bytes = Buffer.from(result.data, 'base64');
  if (bytes.length > 2 * 1024 * 1024 || bytes.toString('base64') !== result.data) throw new Error('Invalid image size/encoding.');
  const decoded = decode(bytes, { useTArray: true, formatAsRGBA: true, tolerantDecoding: false, maxResolutionInMP: 2, maxMemoryUsageInMB: 32 });
  if (decoded.width !== result.width || decoded.height !== result.height) throw new Error('Image dimensions mismatch.');
  return result;
}
