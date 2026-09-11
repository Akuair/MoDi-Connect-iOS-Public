#include "OpusBridge.h"
#include <opus/opus.h>

MoDiOpusEncoderHandle *modi_opus_encoder_create(int sample_rate, int channels, int bitrate,
                                                int complexity, int fec, int packet_loss_percent,
                                                int constrained_vbr, int *error) {
    OpusEncoder *encoder = opus_encoder_create(sample_rate, channels, OPUS_APPLICATION_AUDIO, error);
    if (!encoder || *error != OPUS_OK) return encoder;

    int status = opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_VBR(1));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_VBR_CONSTRAINT(constrained_vbr));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(fec));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(packet_loss_percent));
    if (status == OPUS_OK) status = opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
    if (status != OPUS_OK) {
        opus_encoder_destroy(encoder);
        encoder = NULL;
    }
    *error = status;
    return encoder;
}

int modi_opus_encode(MoDiOpusEncoderHandle *encoder, const int16_t *pcm, int frame_size,
                     unsigned char *output, int output_capacity) {
    return opus_encode(encoder, pcm, frame_size, output, output_capacity);
}

void modi_opus_encoder_destroy(MoDiOpusEncoderHandle *encoder) {
    if (encoder) opus_encoder_destroy(encoder);
}

int modi_opus_decode_once(const unsigned char *packet, int packet_size,
                          int16_t *pcm, int frame_size) {
    int error = OPUS_OK;
    OpusDecoder *decoder = opus_decoder_create(48000, 1, &error);
    if (!decoder || error != OPUS_OK) return error;
    int decoded = opus_decode(decoder, packet, packet_size, pcm, frame_size, 0);
    opus_decoder_destroy(decoder);
    return decoded;
}
