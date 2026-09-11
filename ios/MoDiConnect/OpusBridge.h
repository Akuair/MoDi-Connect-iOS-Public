#pragma once

#include <stdint.h>

typedef struct OpusEncoder MoDiOpusEncoderHandle;

MoDiOpusEncoderHandle *modi_opus_encoder_create(int sample_rate, int channels, int bitrate,
                                               int complexity, int fec, int packet_loss_percent,
                                               int constrained_vbr, int *error);
int modi_opus_encode(MoDiOpusEncoderHandle *encoder, const int16_t *pcm, int frame_size,
                     unsigned char *output, int output_capacity);
void modi_opus_encoder_destroy(MoDiOpusEncoderHandle *encoder);
int modi_opus_decode_once(const unsigned char *packet, int packet_size,
                          int16_t *pcm, int frame_size);
