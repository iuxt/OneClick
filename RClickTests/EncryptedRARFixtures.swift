/*
 * Copyright (c) 2003-2018
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer
 *    in this position and unchanged.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// Test data: https://github.com/libarchive/libarchive/tree/2774b74cb7269c9b5fa89e7d876b11d5a729c421/libarchive/test
// Upstream fixture passwords are public test values: "password".
import Foundation

nonisolated enum EncryptedRARFixtures {
    static let archives: [String: Data] = [
        "test_read_format_rar4_encrypted_filenames.rar": Data(base64Encoded: "UmFyIRoHAM6Zc4AADQAAAAAAAAAAAAAAAAAAAHQLhjMoMLWHQDJeY20c4vaKVtHClR72L6r0d23BE5Sd3EMg5SU6+Cs/bn2n8KU9GCWixDfgW04TYlx8Y8UNczV1XqthmOHsTsvvjtW98xWQjVRzOJ+HWtvn/yck3YlnIAAAAAAAAAAAIiMI9vV7WRujtH8xZ7GclVkWmWAf3pADNOI9qf3+jZB1NVv+SdHwLVrIlk7apU0dQP6o2x7mYowi6cL3hOK0VcyErLYGPvy/8iuY2V22t9CVmaEU5a8qyMJMF9MRyb6eAAAAAAAAAADKiQEJRlpi77vZY9M4Qk0eoAuLGKOuuwrB9R4qDIhm/0mWQmlTBsQOR0LdpcH476QamST1/7WzOpa6uxO8go689GQsPwazhEaM5c+UOhB8zikXurV72lPZEZrPuSA7X90AAAAAAAAAAO8E6Tfe/6OTKeWcRSFXURfW/OPhBa4hBwCiQwzVVeLFqJNoEQ0BPPeEH9HN1f/Cvduf/azulc+VU6TP7YMt+mfWTWJ4v1uszUg88ugRqD6P2fqc/4zejuhSRMcxbcbj7gAAAAAAAAAA8J9Fd+s8JNpIkqv+eRXXow==")!,
        "test_read_format_rar4_solid_encrypted.rar": Data(base64Encoded: "UmFyIRoHADvQcwgADQAAAAAAAAAhYXTElDIAMAAAABIAAAACVW5a7mRXdlgdMwUAIAAAAGEudHh0AAAAAAAAAAAA8PxMG9xMy2AT2JoRQ/GDngHm6HgELpF34wfhD4txehNkP8ZxoByLM9h2IYmKtxkTOc2AzjZWdNSUMgAQAAAAEgAAAAKFFPqpZ1d2WB0zBQAgAAAAYi50eHSPFtXIQVCs9QCwcqA0irXtBqoJ/a/Yr88rM1/4e8MjdNSUMgAQAAAAEgAAAAI1PZqUbld2WB0zBQAgAAAAYy50eHRpsiacgSJgtgCwPkgtkH1h9ySu+/ngRBsNof2erN02dNSUMgAQAAAAEgAAAAIl4bomTWR2WB0zBQAgAAAAZC50eHSjLhrkrtsFzQDw+2GPfqMsDgeBVSdtOdwwjhqmpsQ9ewBABwA=")!,
        "test_read_format_rar5_encrypted_filenames.rar": Data(base64Encoded: "UmFyIRoHAQCuI9KQIQQAAAEPaAuw0KfIvaHedKdxMjSbGbcKghg7J7kA48ppJRDshMehHkYtfQ41TsTW1krt6Tl3x7oj46TcFBvKdO5M3PzcxjhfvPaKM+6VdtWzTK5WbLTVjAZAKU39cHaXSmTHGareMmi1q2J0+Rt3M4QJjUwX3IACEDNux82FP6G5qdUhXD3hLZOVH//RjmJUmafz277uR1+RWwOL0xV4OHCguxCdWrT6eabORj2lcFFtRNvxTsQm67rpS0z3AOSzmSQc60PMdPI3rULZC8LqGEHJ/T2Mm3Ffd+7tpOW7qhPeQ2V30iTNxp2cTxHfLL4EQ9f42IflyMXRjh4iusRr0VhKYKGL0gW9h/JKrh9F2TzMQibzIs3R2OhoO1W1Qu8NFBgqZxNmqF+HvJIqyVLSzEVqvP4hT3Utzq7ySXFw/UEnh3z3BzzIUph/NJ6a7af2VkBmg0nnZsQBR0m7ahocZnQO7HFXN8aeCGIY5D6DWSb1OaMTLdcElWzYjQSp7Pcv6eneNTwR5cHq3/mqP92qNxXphWUcfAbn03co9gd5zQJzK8fzr4xEoO5Bc6rA7R7f6I8I/89e1a/0rPlottbw3qfTA5ZzWGFWsg0QN1cGUl7L/me6FLrm3HG3eAMOd9Dzpbh75hJbutWAVrQRq9gp0WvY3DB9OhEF/Vt8l9zQGckAC0MaoXeO0vwijsZEjCn1Sc3Jx8ZhiqsoVXcEDbGFc+uDNu7VrlfAVWM3zoncn1UBBOLg61LVu8bq7XqNKKyD28RZcpbv7pFfNQQS1MYyEO+tPwY39fSWuL2iVN8iDXbz2b/sDFUwxTWwi00menGYlJJgOoQRxagRx+O525pnIfDSazWQUk8Hj31OBaNlAdbU2mzLr1ssqcSngnENtmV2XS055B91I1iUXTvfA1Hd3HDk8UhFzN/mfPg9zJt1eO72RA==")!,
        "test_read_format_rar5_solid_encrypted.rar": Data(base64Encoded: "UmFyIRoHAQAgtvoRCgEFBgQFAQGAgABhD8WeUgIDPLAABJIAIFVuWu6AQwAFYS50eHQwAQABD4AO+ltBRZAMdjBQiNnLDfQI7VR1p9MLvo+08ad28VAv4g84Lifed3gQH70kCgMCfCGEo4J82gE1pZSt+eqf2NsfSgASsQSTg/Dfo8jerfnnk0KSXvAe89E8IU+RSz6hkSnpWpIfguz8l01nUgIDPJAABJIAID37tWPAQwAFYi50eHQwAQADD4AO+ltBRZAMdjBQiNnLDfQZHnb1t0VBULbYAW3tdK7f4g84Lifed3gQH70kCgMCcmWYpoJ82gEjM46yUVAy4KNVZG4T5HLJHXwcClICAzyQAASSACD/J5yGwEMABWMudHh0MAEAAw+ADvpbQUWQDHYwUIjZyw30W2TcRNmMRpQCQNayPVdi1uIPOC4n3nd4EB+9JAoDAj5I6a6CfNoBiihfqHObfXFsRShGQFWdAkeP7D9SAgM8kAAEkgAgexd0w8BDAAVkLnR4dDABAAMPgA76W0FFkAx2MFCI2csN9GlzaIL1Pzt2pDbf1ZaghGviDzguJ953eBAfvSQKAwJ7xSn0j3zaATngcETEsrz5jjXk4OrZA7Add1ZRAwUEAA==")!,
    ]
}
