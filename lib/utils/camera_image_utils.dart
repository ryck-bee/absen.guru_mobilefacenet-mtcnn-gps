// import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';

Uint8List convertYUV420toNV21(CameraImage image) {
  final int width = image.width;
  final int height = image.height;
  final int ySize = width * height;
  final int uvSize = (width * height) ~/ 2;

  final Uint8List nv21 = Uint8List(ySize + uvSize);

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];

  int offset = 0;
  for (int row = 0; row < height; row++) {
    final int rowStart = row * yPlane.bytesPerRow;
    nv21.setRange(offset, offset + width, yPlane.bytes, rowStart);
    offset += width;
  }

  final int uvRowStride = uPlane.bytesPerRow;
  final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

  int uvIndex = ySize;
  for (int row = 0; row < height ~/ 2; row++) {
    for (int col = 0; col < width ~/ 2; col++) {
      final int uIndex = row * uvRowStride + col * uvPixelStride;
      final int vIndex = row * uvRowStride + col * uvPixelStride;
      nv21[uvIndex++] = vPlane.bytes[vIndex];
      nv21[uvIndex++] = uPlane.bytes[uIndex];
    }
  }

  return nv21;
}

img.Image? convertCameraImageToRgb(CameraImage image) {
  try {
    if (image.format.group != ImageFormatGroup.yuv420) return null;

    final int width = image.width;
    final int height = image.height;
    
    final img.Image converted = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * yPlane.bytesPerRow + x;
        final int uvX = x ~/ 2;
        final int uvY = y ~/ 2;
        final int uvIndex = uvY * uPlane.bytesPerRow + uvX * uvPixelStride;

        final int yp = yPlane.bytes[yIndex];
        final int up = uPlane.bytes[uvIndex];
        final int vp = vPlane.bytes[uvIndex];

        final int r = (yp + 1.402 * (vp - 128)).clamp(0, 255).toInt();
        final int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).clamp(0, 255).toInt();
        final int b = (yp + 1.772 * (up - 128)).clamp(0, 255).toInt();

        converted.setPixelRgb(x, y, r, g, b);
      }
    }
    return converted;
  } catch (e) {
    debugPrint("Error converting camera image: $e");
    return null;
  }
}

img.Image correctCameraRotation(img.Image image, CameraDescription camera) {
  // takePicture() pada device ini sudah menghasilkan gambar tegak.
  // Sensor 270° tidak butuh rotasi tambahan.
  // flipHorizontal DIHAPUS karena MTCNN tidak stabil pada gambar mirror.
  return image;
}

img.Image correctLiveStreamRotation(img.Image image, CameraDescription camera) {
  img.Image rotated = image;
  final int sensorAngle = camera.sensorOrientation;

  if (sensorAngle == 270) {
    rotated = img.copyRotate(rotated, angle: 270);
  } else if (sensorAngle == 90) {
    rotated = img.copyRotate(rotated, angle: 90);
  } else if (sensorAngle == 180) {
    rotated = img.copyRotate(rotated, angle: 180);
  } else {
    rotated = img.copyRotate(rotated, angle: 90);
  }

  // Tidak ada flipHorizontal — MTCNN tidak stabil pada gambar mirror.
  return rotated;
}

void debugPrintCameraUtilError(Object e) {
  // ignore: avoid_print
  print("Gagal konversi CameraImage: $e");
}