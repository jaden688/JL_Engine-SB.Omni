import math

def generate_bass_svg(filename):
    # Canvas dimensions (Snapmaker Artisan bed: 400x400)
    width = 400
    height = 400
    
    # SVG Header
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}mm" height="{height}mm">
    <rect width="100%" height="100%" fill="#f4f4f4" />
    <g transform="translate({width/2}, {height/2})">
    """
    
    # 1. Outer Body Profile (Custom Compact Design to fit < 400mm length)
    # We'll use a continuous path with bezier curves for a modern, sleek shape.
    # Total length from neck heel to butt: ~380mm (fits perfectly)
    body_path = """
    <path d="
        M -35,-190 
        C -35,-190 -80,-150 -120,-80 
        C -160,-10 -180,70 -140,130 
        C -100,190 -40,190 0,190 
        C 40,190 100,190 140,130 
        C 180,70 160,-10 120,-80 
        C 80,-150 35,-190 35,-190 
        L 35,-190 L -35,-190 Z
    """
    
    # Adding arm contour and cutaways for an aggressive bass look
    body_path = """
    <path d="
        M -32,-180 
        C -40,-180 -100,-160 -130,-90 
        C -150,-40 -120,0 -130,50
        C -140,100 -160,140 -100,170
        C -50,190 0,190 0,190
        C 0,190 50,190 100,170
        C 160,140 140,100 130,50
        C 120,0 150,-40 130,-90
        C 100,-160 40,-180 32,-180
        Z
    " fill="none" stroke="black" stroke-width="2" />
    """
    svg += body_path

    # 2. Neck Pocket
    # Standard bass neck heel is 63.5mm (2.5") wide, approx 90mm deep.
    # Center it at the top.
    pocket_w = 63.5
    pocket_h = 90
    pocket_x = -pocket_w / 2
    pocket_y = -180 # Top edge of the body
    svg += f'<rect x="{pocket_x}" y="{pocket_y}" width="{pocket_w}" height="{pocket_h}" fill="none" stroke="red" stroke-width="2" />\n'
    svg += f'<text x="0" y="{pocket_y + pocket_h/2}" font-family="Arial" font-size="10" text-anchor="middle" fill="red">Neck Pocket (16mm depth)</text>\n'

    # 3. Pickup Cavity (Standard Soapbar / EMG style - 100mm x 35mm)
    pu_w = 100
    pu_h = 38
    pu_x = -pu_w / 2
    pu_y = -20 # Placed right in the "sweet spot"
    svg += f'<rect x="{pu_x}" y="{pu_y}" width="{pu_w}" height="{pu_h}" rx="5" fill="none" stroke="blue" stroke-width="2" />\n'
    svg += f'<text x="0" y="{pu_y + pu_h/2 + 3}" font-family="Arial" font-size="10" text-anchor="middle" fill="blue">Pickup (19mm depth)</text>\n'

    # 4. Bridge Placement Line (Top-loading Hardtail Bridge)
    bridge_w = 80
    bridge_h = 45
    bridge_x = -bridge_w / 2
    bridge_y = 60
    svg += f'<rect x="{bridge_x}" y="{bridge_y}" width="{bridge_w}" height="{bridge_h}" fill="none" stroke="purple" stroke-width="2" stroke-dasharray="4" />\n'
    svg += f'<text x="0" y="{bridge_y + bridge_h/2 + 3}" font-family="Arial" font-size="10" text-anchor="middle" fill="purple">Bridge</text>\n'

    # 5. Control Cavity (Rear-routed, but drawn here for the front drill holes)
    ctrl_cx = 90
    ctrl_cy = 90
    svg += f'<circle cx="{ctrl_cx}" cy="{ctrl_cy}" r="25" fill="none" stroke="green" stroke-width="2" />\n'
    svg += f'<circle cx="{ctrl_cx - 15}" cy="{ctrl_cy - 10}" r="3" fill="green" />\n' # Vol knob
    svg += f'<circle cx="{ctrl_cx + 10}" cy="{ctrl_cy + 15}" r="3" fill="green" />\n' # Tone knob
    svg += f'<text x="{ctrl_cx}" y="{ctrl_cy - 30}" font-family="Arial" font-size="10" text-anchor="middle" fill="green">Controls</text>\n'

    # Centerline for alignment
    svg += '<line x1="0" y1="-200" x2="0" y2="200" stroke="gray" stroke-width="1" stroke-dasharray="5,5" />\n'

    svg += """
    </g>
    </svg>
    """
    
    with open(filename, "w") as f:
        f.write(svg)
    print(f"Generated {filename} successfully.")

if __name__ == "__main__":
    generate_bass_svg("C:\\Users\\J_lin\\Desktop\\Custom_400mm_Bass_Body.svg")
