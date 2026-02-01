import os
from PIL import Image, ImageChops

def smart_crop(image_path):
    img = Image.open(image_path).convert("RGBA")
    width, height = img.size
    
    # 1. Detect background color (assume top-left is background)
    bg_color = img.getpixel((0, 0))
    print(f"Detected background color: {bg_color}")
    
    # 2. Find bounding box of content (diff from background)
    bg = Image.new("RGBA", img.size, bg_color)
    diff = ImageChops.difference(img, bg)
    diff = ImageChops.add(diff, diff, 2.0, -100) # Enhance contrast
    bbox = diff.getbbox()
    
    if bbox:
        print(f"Content BBox: {bbox}")
        # bbox is (left, top, right, bottom)
        content_width = bbox[2] - bbox[0]
        content_height = bbox[3] - bbox[1]
        
        # 3. Crop to the content
        cropped = img.crop(bbox)
        
        # 4. Zoom in slightly to remove rounded corners (if any)
        # If the content was a rounded square on white, the bbox is the square's bounds.
        # But the corners of that bbox are still white pixels (from the background).
        # To make it full-bleed, we need to crop *inside* the rounded corners.
        # A typical iOS icon radius is ~22% of size. 
        # But forcing a square crop inside the rounded rect might lose too much.
        # Let's try zooming in by 3% relative to the bbox size to be safe, 
        # or just fill the transparency/white corners?
        # Filling is hard. Let's Zoom.
        
        # Let's assume the user wants to remove the white frame.
        # If I just crop to bbox, I have a square with white corners (if it was rounded).
        # Let's crop 15 pixels inside the bbox from all sides?
        
        zoom_margin = int(content_width * 0.05) # 5% zoom in
        if zoom_margin < 1: zoom_margin = 0
        
        print(f"Zooming in by {zoom_margin}px to cut corners...")
        
        final_crop_box = (
            zoom_margin, 
            zoom_margin, 
            content_width - zoom_margin, 
            content_height - zoom_margin
        )
        
        final_img = cropped.crop(final_crop_box)
        
        # 5. Resize to 1024x1024
        final_img = final_img.resize((1024, 1024), Image.Resampling.LANCZOS)
        
        # Save
        final_img.save(image_path)
        print(f"Saved fixed icon to {image_path}")
        
    else:
        print("Could not detect content bounding box.")

image_path = "/Users/inazumimakoto/Desktop/shift/ShiftSync/ShiftSync/Media.xcassets/AppIcon.appiconset/Icon.png"
smart_crop(image_path)
