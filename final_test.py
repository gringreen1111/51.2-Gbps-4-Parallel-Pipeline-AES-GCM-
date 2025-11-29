import customtkinter as ctk
import tkinter as tk
import threading
import serial
import time
import os
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

# ============================================================
# 디자인 설정
# ============================================================
ctk.set_appearance_mode("Dark")
ctk.set_default_color_theme("green")

FONT_HEADER = ("Roboto Medium", 24)
FONT_SUBHEADER = ("Roboto Medium", 16)
FONT_DATA = ("Consolas", 12)
FONT_STATUS = ("Roboto Medium", 14)

COLOR_BG = "#1a1a1a"
COLOR_PANEL = "#2b2b2b"
COLOR_ACCENT = "#2CC985"
COLOR_TEXT = "#E0E0E0"
COLOR_ERROR = "#FF4444"
COLOR_PAUSE = "#8B0000"  # PAUSE 버튼용 어두운 빨간색
COLOR_WARN = "#FF4444"   # PAUSING 상태 노란색

# ============================================================
# 암호화 로직
# ============================================================
def aes_ecb_encrypt_one_block(key, data_16b):
    cipher = Cipher(algorithms.AES(key), modes.ECB(), backend=default_backend())
    encryptor = cipher.encryptor()
    return encryptor.update(data_16b) + encryptor.finalize()

def gf_mult(x, y):
    R = 0xE1000000000000000000000000000000
    z = 0
    v = y
    for i in range(128):
        if (x >> (127 - i)) & 1: z ^= v
        if v & 1: v = (v >> 1) ^ R
        else:     v >>= 1
    return z

# ============================================================
# GUI 클래스
# ============================================================
class AES_GCM_Dashboard(ctk.CTk):
    def __init__(self):
        super().__init__()

        # 윈도우 설정
        self.title("FPGA 51.2Gbps Crypto Engine Dashboard")
        self.geometry("1600x900")
        self.attributes("-fullscreen", True)
        self.configure(fg_color=COLOR_BG)
        
        self.bind("<Escape>", lambda e: self.destroy())

        # --- 통신 제어 변수 ---
        self.ser = None
        self.is_running = False        
        self.stop_requested = False
        self.is_key_set = False
        self.is_looping = ctk.BooleanVar(value=False)
        
        # [NEW] 총 데이터량 누적 변수
        self.total_encrypted_bytes = 0

        self.setup_ui()
        
        # 검증용 데이터 초기화
        self.KEY = b'\x00' * 16
        self.H_int = 0
        self.AAD = b'\x00' * 16
        self.NONCE_INIT = b'\x00' * 16

    def setup_ui(self):
        # --- [1] Header Area ---
        header_frame = ctk.CTkFrame(self, fg_color="transparent")
        header_frame.pack(fill="x", padx=40, pady=(30, 20))

        title_label = ctk.CTkLabel(header_frame, text="AES-GCM ACCELERATOR", font=("Orbitron", 36, "bold"), text_color=COLOR_ACCENT)
        title_label.pack(side="left")

        subtitle_label = ctk.CTkLabel(header_frame, text=" // XILINX ARTIX-7 FPGA HARDWARE OFFLOAD VERIFIER", font=("Consolas", 18), text_color="#888")
        subtitle_label.pack(side="left", padx=10, pady=(10, 0))

        exit_btn = ctk.CTkButton(header_frame, text="EXIT SYSTEM", width=120, fg_color=COLOR_ERROR, hover_color="#cc0000", command=self.destroy)
        exit_btn.pack(side="right")

        # --- [2] Control Panel ---
        ctrl_frame = ctk.CTkFrame(self, fg_color=COLOR_PANEL, corner_radius=10)
        ctrl_frame.pack(fill="x", padx=40, pady=10, ipady=10)

        ctk.CTkLabel(ctrl_frame, text="PORT:", font=FONT_STATUS).pack(side="left", padx=(20, 5))
        self.port_entry = ctk.CTkEntry(ctrl_frame, width=100, font=FONT_DATA)
        self.port_entry.insert(0, "COM4")
        self.port_entry.pack(side="left", padx=5)

        # 버튼 설정
        self.btn_connect = ctk.CTkButton(ctrl_frame, text="INITIALIZE LINK", font=FONT_STATUS, width=180, command=self.toggle_start)
        self.btn_connect.pack(side="left", padx=20)

        self.chk_loop = ctk.CTkCheckBox(ctrl_frame, text="INFINITE STREAM MODE", variable=self.is_looping, font=FONT_STATUS, text_color="white")
        self.chk_loop.pack(side="left", padx=20)

        self.lbl_status = ctk.CTkLabel(ctrl_frame, text="SYSTEM IDLE", font=("Roboto", 16, "bold"), text_color="#888")
        self.lbl_status.pack(side="right", padx=30)

        # --- [3] Main Dashboard Area ---
        main_frame = ctk.CTkFrame(self, fg_color="transparent")
        main_frame.pack(fill="both", expand=True, padx=40, pady=10)
        main_frame.grid_columnconfigure(0, weight=1) # Left (Pipeline)
        main_frame.grid_columnconfigure(1, weight=2) # Right (Data)

        # === [LEFT COLUMN] ===
        flow_frame = ctk.CTkFrame(main_frame, fg_color=COLOR_PANEL, corner_radius=15)
        flow_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        
        ctk.CTkLabel(flow_frame, text="AES ENCRYPTION", font=FONT_SUBHEADER, text_color="#AAA").pack(pady=(20, 10))
        
        # Pipeline Steps
        self.step_labels = {}
        steps = ["KEY INJECTION", "AAD SETUP", "IV SETUP", "DATA STREAM (16384Bytes)", "AEAD TAG VERIFICATION"]
        
        self.flow_container = ctk.CTkFrame(flow_frame, fg_color="transparent")
        self.flow_container.pack(fill="both", expand=True, padx=20, pady=10)

        for i, step in enumerate(steps):
            step_box = ctk.CTkFrame(self.flow_container, fg_color="#222", height=60, corner_radius=8, border_width=0)
            step_box.pack(fill="x", pady=8)
            step_box.pack_propagate(False) 
            
            indicator = ctk.CTkLabel(step_box, text="●", font=("Arial", 24), text_color="#444")
            indicator.place(relx=0.05, rely=0.5, anchor="w")
            
            lbl = ctk.CTkLabel(step_box, text=step, font=("Roboto", 14, "bold"), text_color="#666")
            lbl.place(relx=0.15, rely=0.5, anchor="w")
            
            self.step_labels[step] = (indicator, lbl, step_box)

        # 1. Status Container (가장 아래)
        status_container = ctk.CTkFrame(flow_frame, fg_color="transparent")
        status_container.pack(fill="x", padx=20, pady=20, side="bottom")
        
        status_container.grid_columnconfigure(0, weight=1, uniform="equal")
        status_container.grid_columnconfigure(1, weight=1, uniform="equal")

        # 왼쪽: Block Check
        self.box_enc = ctk.CTkFrame(status_container, fg_color="#222", height=100, corner_radius=10, border_width=2, border_color="#444")
        self.box_enc.grid(row=0, column=0, sticky="ew", padx=(0, 10))
        self.box_enc.pack_propagate(False) # 높이 고정
        
        ctk.CTkLabel(self.box_enc, text="BLOCK CHECK", font=("Roboto", 12, "bold"), text_color="#888").pack(pady=(20, 5))
        
        # 중앙 정렬용 내부 프레임
        self.enc_text_frame = ctk.CTkFrame(self.box_enc, fg_color="transparent", height=40)
        self.enc_text_frame.pack(pady=0, padx=10, fill="x")
        
        self.enc_text_frame.grid_columnconfigure(0, weight=1) # Left space
        self.enc_text_frame.grid_columnconfigure(2, weight=1) # Right space
        
        # 1) Current Count
        self.lbl_enc_curr = ctk.CTkLabel(self.enc_text_frame, text="0", font=("Consolas", 24, "bold"), text_color="white")
        self.lbl_enc_curr.grid(row=0, column=0, sticky="e", padx=(0, 5))
        
        # 2) Separator
        ctk.CTkLabel(self.enc_text_frame, text="/", font=("Consolas", 24, "bold"), text_color="gray").grid(row=0, column=1)
        
        # 3) Total Count
        ctk.CTkLabel(self.enc_text_frame, text="1024", font=("Consolas", 24, "bold"), text_color="gray").grid(row=0, column=2, sticky="w", padx=(5, 0))


        # 오른쪽: Auth Result
        self.box_auth = ctk.CTkFrame(status_container, fg_color="#222", height=100, corner_radius=10, border_width=2, border_color="#444")
        self.box_auth.grid(row=0, column=1, sticky="ew", padx=(10, 0))
        self.box_auth.pack_propagate(False)

        ctk.CTkLabel(self.box_auth, text="AUTHENTICATION RESULT", font=("Roboto", 12, "bold"), text_color="#888").pack(pady=(20, 0))
        self.lbl_auth_res = ctk.CTkLabel(self.box_auth, text="WAITING", font=("Orbitron", 20, "bold"), text_color="#666")
        self.lbl_auth_res.pack(pady=(5, 15))

        # 2. Info Container (Key & IV & Total Data)
        self.info_container = ctk.CTkFrame(flow_frame, fg_color="#222", corner_radius=10, border_width=1, border_color="#444")
        self.info_container.pack(fill="x", padx=20, pady=(0, 10), side="bottom")

        # Key Label
        ctk.CTkLabel(self.info_container, text="CURRENT SESSION KEY", font=("Roboto", 10, "bold"), text_color="#888").pack(anchor="w", padx=15, pady=(10, 0))
        self.lbl_key_val = ctk.CTkLabel(self.info_container, text="WAITING FOR KEY...", font=("Consolas", 14), text_color=COLOR_ACCENT)
        self.lbl_key_val.pack(anchor="w", padx=15, pady=(2, 5))

        # IV Label
        ctk.CTkLabel(self.info_container, text="CURRENT IV (NONCE)", font=("Roboto", 10, "bold"), text_color="#888").pack(anchor="w", padx=15, pady=(5, 0))
        self.lbl_iv_val = ctk.CTkLabel(self.info_container, text="WAITING FOR IV...", font=("Consolas", 14), text_color="#4AA")
        self.lbl_iv_val.pack(anchor="w", padx=15, pady=(2, 5))

        # [NEW] Total Encrypted Data Label
        ctk.CTkLabel(self.info_container, text="TOTAL ENCRYPTED DATA BY UART INTERFACE", font=("Roboto", 10, "bold"), text_color="#888").pack(anchor="w", padx=15, pady=(5, 0))
        self.lbl_total_data = ctk.CTkLabel(self.info_container, text="0 Bytes", font=("Consolas", 14), text_color=COLOR_ACCENT)
        self.lbl_total_data.pack(anchor="w", padx=15, pady=(2, 10))


        # === [RIGHT COLUMN] ===
        data_frame = ctk.CTkFrame(main_frame, fg_color=COLOR_PANEL, corner_radius=15)
        data_frame.grid(row=0, column=1, sticky="nsew", padx=(10, 0))

        ctk.CTkLabel(data_frame, text="REAL-TIME TRAFFIC MONITOR", font=FONT_SUBHEADER, text_color="#AAA").pack(pady=(20, 5))

        self.progress_bar = ctk.CTkProgressBar(data_frame, height=15, progress_color=COLOR_ACCENT)
        self.progress_bar.set(0)
        self.progress_bar.pack(fill="x", padx=30, pady=10)
        self.lbl_progress = ctk.CTkLabel(data_frame, text="BLOCK: 0 / 1024", font=("Consolas", 12), text_color="#AAA")
        self.lbl_progress.pack(anchor="e", padx=30)

        terminal_frame = ctk.CTkFrame(data_frame, fg_color="transparent")
        terminal_frame.pack(fill="both", expand=True, padx=20, pady=10)
        terminal_frame.grid_columnconfigure(0, weight=1)
        terminal_frame.grid_columnconfigure(1, weight=1)

        ctk.CTkLabel(terminal_frame, text="TX (PLAINTEXT)", font=("Consolas", 12, "bold"), text_color="#4AA").grid(row=0, column=0, sticky="w")
        self.txt_pt = ctk.CTkTextbox(terminal_frame, font=("Consolas", 14), fg_color="#111", text_color="#4AA", height=400, activate_scrollbars=True)
        self.txt_pt.grid(row=1, column=0, sticky="nsew", padx=(0, 5))

        ctk.CTkLabel(terminal_frame, text="RX (CIPHERTEXT)", font=("Consolas", 12, "bold"), text_color="#A4A").grid(row=0, column=1, sticky="w")
        self.txt_ct = ctk.CTkTextbox(terminal_frame, font=("Consolas", 14), fg_color="#111", text_color="#A4A", height=400, activate_scrollbars=True)
        self.txt_ct.grid(row=1, column=1, sticky="nsew", padx=(5, 0))

        compare_frame = ctk.CTkFrame(data_frame, fg_color="#1a1a1a", corner_radius=10)
        compare_frame.pack(fill="x", padx=20, pady=20)
        
        ctk.CTkLabel(compare_frame, text="EXPECTED TAG:", font=("Consolas", 12), text_color="#AAA").grid(row=0, column=0, padx=15, pady=10, sticky="e")
        self.lbl_tag_exp = ctk.CTkLabel(compare_frame, text="--------------------------------", font=("Consolas", 16), text_color="white")
        self.lbl_tag_exp.grid(row=0, column=1, sticky="w")

        ctk.CTkLabel(compare_frame, text="RECEIVED TAG:", font=("Consolas", 12), text_color="#AAA").grid(row=1, column=0, padx=15, pady=10, sticky="e")
        self.lbl_tag_rx = ctk.CTkLabel(compare_frame, text="--------------------------------", font=("Consolas", 16), text_color="white")
        self.lbl_tag_rx.grid(row=1, column=1, sticky="w")

    # ============================================================
    # 로직
    # ============================================================
    def set_step_active(self, step_name):
        for name, (ind, lbl, box) in self.step_labels.items():
            ind.configure(text_color="#444")
            lbl.configure(text_color="#666")
            box.configure(border_width=0)
        
        if step_name in self.step_labels:
            ind, lbl, box = self.step_labels[step_name]
            ind.configure(text_color=COLOR_ACCENT)
            lbl.configure(text_color="white")
            box.configure(border_width=2, border_color=COLOR_ACCENT)

    def log_data(self, pt, ct):
        self.txt_pt.insert("0.0", f"> {pt}\n")
        self.txt_ct.insert("0.0", f"< {ct}\n")
        
        if float(self.txt_pt.index("end")) > 10000:
            self.txt_pt.delete("10000.0", "end")
            self.txt_ct.delete("10000.0", "end")

    def toggle_start(self):
        if not self.is_running:
            try:
                port = self.port_entry.get()
                if self.ser is None or not self.ser.is_open:
                    self.ser = serial.Serial(port, 115200, timeout=2)

                self.is_running = True
                self.stop_requested = False
                
                self.btn_connect.configure(text="PAUSE TEST", fg_color=COLOR_PAUSE)
                self.lbl_status.configure(text="SYSTEM RUNNING", text_color=COLOR_ACCENT)
                
                self.worker_thread = threading.Thread(target=self.process_thread)
                self.worker_thread.daemon = True
                self.worker_thread.start()
            except Exception as e:
                print(e)
                self.lbl_status.configure(text="CONNECTION ERROR", text_color=COLOR_ERROR)
        else:
            self.stop_requested = True
            self.btn_connect.configure(text="PAUSING...", fg_color=COLOR_WARN, state="disabled")
            self.lbl_status.configure(text="FINISHING BATCH...", text_color=COLOR_WARN)

    def process_thread(self):
        try:
            # [1] Key Generation & Display
            if not self.is_key_set:
                self.set_step_active("KEY INJECTION")
                self.KEY = os.urandom(16)
                self.H_int = int.from_bytes(self.KEY, 'big')
                
                # Update Key Label
                self.lbl_key_val.configure(text=self.KEY.hex(' ').upper())
                
                self.ser.write(self.KEY)
                time.sleep(0.1)
                self.is_key_set = True
            else:
                print("Skipping Key Exchange: Using previous Key")
                self.lbl_key_val.configure(text=self.KEY.hex(' ').upper())

            while self.is_running:
                # UI 초기화
                self.box_enc.configure(border_color="#444")
                self.lbl_enc_curr.configure(text="0", text_color="white") # Reset Count
                self.box_auth.configure(border_color="#444")
                self.lbl_auth_res.configure(text="WAITING", text_color="#666")

                # [2] AAD & IV Generation & Display
                self.AAD = os.urandom(16)
                self.NONCE_INIT = os.urandom(16)
                current_counter = int.from_bytes(self.NONCE_INIT, 'big')
                
                # Update IV Label
                self.lbl_iv_val.configure(text=self.NONCE_INIT.hex(' ').upper())
                
                tag_int = 0
                AAD_int = int.from_bytes(self.AAD, 'big')
                tag_int = gf_mult(tag_int ^ AAD_int, self.H_int)

                self.set_step_active("AAD SETUP")
                self.ser.write(self.AAD)
                time.sleep(0.05)

                self.set_step_active("IV SETUP")
                self.ser.write(self.NONCE_INIT)
                time.sleep(0.05)

                # [3] Data Stream
                self.set_step_active("DATA STREAM (16384Bytes)")
                
                for i in range(1024):
                    if not self.ser.is_open: 
                        self.is_running = False
                        break
                    
                    pt_bytes = os.urandom(16)
                    self.ser.write(pt_bytes)
                    rx_ct = self.ser.read(16)
                    
                    if len(rx_ct) != 16:
                        self.is_running = False; break

                    # Verify
                    counter_block = current_counter.to_bytes(16, 'big')
                    keystream = aes_ecb_encrypt_one_block(self.KEY, counter_block)
                    pt_int = int.from_bytes(pt_bytes, 'big')
                    ks_int = int.from_bytes(keystream, 'big')
                    exp_ct_bytes = (pt_int ^ ks_int).to_bytes(16, 'big')

                    rx_ct_int = int.from_bytes(rx_ct, 'big')
                    tag_int = gf_mult(tag_int ^ rx_ct_int, self.H_int)
                    current_counter += 1
                    
                    # [NEW] 총 데이터량 업데이트
                    self.total_encrypted_bytes += 16

                    if i % 4 == 0 or i == 1023:
                        self.log_data(pt_bytes.hex().upper(), rx_ct.hex().upper())

                    if i % 4 == 0 or i == 1023:
                        self.progress_bar.set((i+1)/1024)
                        self.lbl_progress.configure(text=f"BLOCK: {i+1} / 1024")
                        self.lbl_enc_curr.configure(text=f"{i+1}")
                        
                        # [NEW] 총 데이터량 라벨 업데이트 (단위 변환)
                        if self.total_encrypted_bytes < 1024:
                            data_str = f"{self.total_encrypted_bytes} Bytes"
                        elif self.total_encrypted_bytes < 1024**2:
                            data_str = f"{self.total_encrypted_bytes/1024:.2f} KB"
                        else:
                            data_str = f"{self.total_encrypted_bytes/(1024**2):.2f} MB"
                        self.lbl_total_data.configure(text=data_str)
                    
                    if rx_ct != exp_ct_bytes:
                        self.is_running = False
                        self.box_enc.configure(border_color=COLOR_ERROR)
                        self.lbl_enc_curr.configure(text="ERR", text_color=COLOR_ERROR)
                        break

                if not self.is_running: break

                # [4] Tag Check
                self.set_step_active("AEAD TAG VERIFICATION")
                
                LEN_val = (128 << 64) | (1024 * 128)
                tag_int = gf_mult(tag_int ^ LEN_val, self.H_int)
                expected_tag_hex = hex(tag_int)[2:].zfill(32).upper()

                rx_tag = self.ser.read(16)
                rx_tag_hex = rx_tag.hex().upper()

                self.lbl_tag_exp.configure(text=expected_tag_hex)
                self.lbl_tag_rx.configure(text=rx_tag_hex)

                if rx_tag_hex == expected_tag_hex:
                    self.lbl_auth_res.configure(text="SUCCESS", text_color=COLOR_ACCENT)
                    self.box_auth.configure(border_color=COLOR_ACCENT)
                else:
                    self.lbl_auth_res.configure(text="FAILED", text_color=COLOR_ERROR)
                    self.box_auth.configure(border_color=COLOR_ERROR)
                    self.is_running = False
                    self.btn_connect.configure(text="INITIALIZE LINK", fg_color=COLOR_ACCENT, state="normal")
                    break

                if self.stop_requested:
                    self.is_running = False
                    self.btn_connect.configure(text="RESTART TEST", fg_color=COLOR_ACCENT, state="normal")
                    self.lbl_status.configure(text="PAUSED (KEY RETAINED)", text_color="white")
                    break
                
                if not self.is_looping.get():
                    self.is_running = False
                    self.btn_connect.configure(text="RESTART TEST", fg_color=COLOR_ACCENT, state="normal")
                    self.lbl_status.configure(text="TEST COMPLETE", text_color="white")
                    break
                
                time.sleep(0.2)

        except Exception as e:
            print(f"Thread Error: {e}")
            self.is_running = False
            self.btn_connect.configure(text="INITIALIZE LINK", fg_color=COLOR_ACCENT, state="normal")
            self.is_key_set = False

if __name__ == "__main__":
    app = AES_GCM_Dashboard()
    app.mainloop()