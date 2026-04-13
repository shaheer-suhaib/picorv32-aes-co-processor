import sys, os

def main():
    if len(sys.argv) < 2:
        print("Usage: python wipe_sd.py \\\\.\\PhysicalDrive1")
        return
        
    drive = sys.argv[1]
    
    try:
        # Create a block of 1 Megabyte of purely zero bytes
        zero_block = b'\x00' * (1024 * 1024)
        
        with open(drive, 'r+b') as f:
            for i in range(10): # Wipe first 10 MB
                f.write(zero_block)
                print(f"Wiped {i+1} MB...", end='\r')
                
        print(f"\nSuccessfully wiped the first 10MB of {drive}. It is completely clean for the FPGA!")
    except PermissionError:
        print("==================================================================")
        print("PermissionError: You must run this terminal as Administrator to write to physical drives on Windows.")
        print("Please open an Administrator command prompt or PowerShell and run the command again.")
        print("==================================================================")
        sys.exit(1)
    except Exception as e:
        print(f"Error wiping SD card: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
